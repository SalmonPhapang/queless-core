-- =====================================================================
-- Migration: 20260915_payment_failure_tracking
--
-- Problem:
--   When a Paystack attempt did not complete, nothing structured was
--   recorded about WHY. The reason only existed as raw Paystack payloads
--   buried in payments.metadata:
--
--     metadata -> 'paystack_verify_response' -> 'gateway_response'
--     metadata -> 'last_webhook_event' -> 'data' -> 'gateway_response'
--
--   Both are written by whichever server path happened to run, in
--   Paystack's own shape, and are absent entirely when the customer simply
--   walked away from the checkout. So the app had to dig through nested
--   JSON and guess, and operations could not answer "how many payments
--   failed on insufficient funds this week?" without the same guesswork.
--
-- What this adds:
--   * payments.failure_kind    -- closed vocabulary, see the CHECK below.
--   * payments.failure_reason  -- the raw text Paystack gave us.
--   * payments.failure_status  -- the raw Paystack transaction status.
--   * payments.failure_source  -- who recorded it, and therefore how much
--                                 it can be trusted.
--   * payments.failure_at      -- when the attempt failed.
--   * a backfill of those from the payloads already sitting in metadata,
--     so existing failed payments become readable too.
--
-- The write rules (enforced by the writers, not the table, because they
-- need to compare against the current row):
--   * a completed/refunded payment is never given a failure,
--   * a server-observed reason (initialize / verify / webhook) is never
--     overwritten by a client's guess,
--   * a specific kind is never replaced by 'unknown'.
--
-- Clearing: a payment that later succeeds has these columns set back to
-- NULL (see verify-paystack-split / paystack-webhook), so a stale failure
-- can never describe a paid order.
--
-- Safe to re-run: columns are IF NOT EXISTS, constraints are dropped
-- first, and the backfill only fills rows that are still blank.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS failure_kind   text,
  ADD COLUMN IF NOT EXISTS failure_reason text,
  ADD COLUMN IF NOT EXISTS failure_status text,
  ADD COLUMN IF NOT EXISTS failure_source text,
  ADD COLUMN IF NOT EXISTS failure_at     timestamptz;

COMMENT ON COLUMN public.payments.failure_kind IS
  'Why the last Paystack attempt failed, in the closed vocabulary the customer '
  'app renders (mirrors PaymentFailureKind in lib/models/payment_failure.dart '
  'and PAYMENT_FAILURE_KINDS in supabase/functions/_shared/payment-failure.ts). '
  'NULL means no failure is currently recorded for this payment.';

COMMENT ON COLUMN public.payments.failure_reason IS
  'The raw text Paystack supplied (gateway_response or message). Kept verbatim '
  'for support and for re-classification; never shown to a customer.';

COMMENT ON COLUMN public.payments.failure_status IS
  'Raw Paystack transaction status for the failed attempt (failed, abandoned, '
  'cancelled, ...).';

COMMENT ON COLUMN public.payments.failure_source IS
  'Who recorded the failure: initialize | paystack_verify | paystack_webhook | '
  'redirect are server-observed and outrank client guesses.';

COMMENT ON COLUMN public.payments.failure_at IS
  'When the failed attempt was recorded.';

-- ---------------------------------------------------------------------
-- 2. Constraints
--
--    failure_kind is a CLOSED list on purpose: unknown is the catch-all, so
--    a new Paystack phrasing can never require a migration, and a typo or a
--    drifting client can never write a kind the app cannot render.
-- ---------------------------------------------------------------------
ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_failure_kind_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_failure_kind_check
  CHECK (
    failure_kind IS NULL
    OR failure_kind IN (
      'cancelled', 'declined', 'insufficientFunds', 'expiredCard',
      'invalidCardDetails', 'authenticationFailed', 'cardNotSupported',
      'limitReached', 'duplicateAttempt', 'timedOut', 'network',
      'configuration', 'unavailable', 'unknown'
    )
  );

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_failure_source_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_failure_source_check
  CHECK (
    failure_source IS NULL
    OR failure_source IN (
      'client', 'initialize', 'paystack_verify', 'paystack_webhook',
      'redirect', 'manual'
    )
  );

-- A kind without a source (or vice versa) would mean a half-written failure.
ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_failure_consistent;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_failure_consistent
  CHECK (
    (failure_kind IS NULL AND failure_source IS NULL AND failure_at IS NULL)
    OR (failure_kind IS NOT NULL AND failure_source IS NOT NULL)
  );

-- ---------------------------------------------------------------------
-- 3. Index for operations: "what is failing lately, and why?"
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_payments_failure_kind
  ON public.payments (failure_kind, failure_at DESC)
  WHERE failure_kind IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. SQL mirror of the failure classifier
--
--    Used by the backfill below, and available to future SQL-side writers
--    (manual repairs, reports). The keyword order matters and mirrors
--    PaymentFailure.fromReason in lib/models/payment_failure.dart and
--    classifyPaymentFailure in supabase/functions/_shared/payment-failure.ts.
--    Keep the three in step; the CHECK constraint above is what makes a
--    mismatch fail loudly instead of quietly writing nonsense.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.classify_payment_failure(
  reason text,
  status text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(btrim(reason), '') = '' AND coalesce(btrim(status), '') = ''
      THEN NULL

    -- Order matters: 'cancelled' also contains 'cancel', and
    -- 'insufficient funds' must not fall through to 'invalid'.
    WHEN v ~ 'cancel|abandon|closed the|customer exited'
      THEN 'cancelled'
    WHEN v ~ 'insufficient|not enough|no funds|low balance'
      THEN 'insufficientFunds'
    WHEN v ~ 'expired'
      THEN 'expiredCard'
    WHEN v ~ 'limit'
      THEN 'limitReached'
    WHEN v ~ 'duplicate'
      THEN 'duplicateAttempt'
    WHEN v ~ 'timed out|timeout|time out'
      THEN 'timedOut'
    WHEN v ~ 'not permitted|not supported|unsupported|card type|not allowed for this'
      THEN 'cardNotSupported'
    WHEN v ~ '3d|3-d|authentication|secure|otp|verification'
      THEN 'authenticationFailed'
    WHEN v ~ 'declin|do not honor|not authorised|not authorized|not successful|unsuccessful'
      THEN 'declined'
    -- Before the card-detail check: 'invalid subaccount' and 'invalid split'
    -- are OUR configuration problems, not the customer's card.
    WHEN v ~ 'subaccount|split|not configured|configuration|invalid key|invalid signature'
      THEN 'configuration'
    WHEN v ~ 'cvv|invalid|incorrect|wrong'
      THEN 'invalidCardDetails'
    WHEN v ~ 'internal server|server error|unavailable|bad gateway'
      THEN 'unavailable'
    WHEN v ~ 'network|connection|socket|internet'
      THEN 'network'
    -- A bare non-success status: the card is the overwhelmingly common cause.
    WHEN v ~ 'fail'
      THEN 'declined'
    ELSE 'unknown'
  END
  FROM (
    SELECT lower(
             coalesce(btrim(reason), '') || ' ' || coalesce(btrim(status), '')
           ) AS v
  ) AS combined;
$$;

COMMENT ON FUNCTION public.classify_payment_failure(text, text) IS
  'Classifies a Paystack failure reason/status into the closed failure_kind '
  'vocabulary. Mirrors the customer app and edge-function classifiers.';

-- ---------------------------------------------------------------------
-- 5. Backfill from the payloads that are already in metadata
--
--    Only for payments that are not completed/refunded, and only from
--    payloads that do NOT describe a success -- otherwise a payment that
--    eventually went through would be labelled as a failure.
-- ---------------------------------------------------------------------
WITH payloads AS (
  SELECT
    p.id,
    p.updated_at,
    CASE
      WHEN lower(coalesce(p.metadata -> 'paystack_verify_response' ->> 'status', '')) <> 'success'
        THEN p.metadata -> 'paystack_verify_response'
    END AS verify_payload,
    CASE
      WHEN lower(coalesce(p.metadata -> 'last_webhook_event' -> 'data' ->> 'status', '')) <> 'success'
        THEN p.metadata -> 'last_webhook_event' -> 'data'
    END AS webhook_payload
  FROM public.payments p
  WHERE lower(coalesce(p.status, '')) NOT IN ('completed', 'refunded')
),
facts AS (
  SELECT
    id,
    updated_at,
    coalesce(
      nullif(verify_payload ->> 'gateway_response', ''),
      nullif(verify_payload ->> 'message', '')
    ) AS verify_reason,
    nullif(verify_payload ->> 'status', '') AS verify_status,
    coalesce(
      nullif(webhook_payload ->> 'gateway_response', ''),
      nullif(webhook_payload ->> 'message', '')
    ) AS webhook_reason,
    nullif(webhook_payload ->> 'status', '') AS webhook_status
  FROM payloads
)
UPDATE public.payments p
   SET failure_reason = coalesce(f.verify_reason, f.webhook_reason),
       failure_status = coalesce(f.verify_status, f.webhook_status),
       failure_source = CASE
         WHEN f.verify_reason IS NOT NULL OR f.verify_status IS NOT NULL
           THEN 'paystack_verify'
         ELSE 'paystack_webhook'
       END,
       failure_at = coalesce(f.updated_at, now())
  FROM facts f
 WHERE p.id = f.id
   AND p.failure_kind IS NULL
   AND (
     f.verify_reason IS NOT NULL OR f.verify_status IS NOT NULL
     OR f.webhook_reason IS NOT NULL OR f.webhook_status IS NOT NULL
   );

-- Classify whatever the backfill just recorded.
UPDATE public.payments p
   SET failure_kind = public.classify_payment_failure(p.failure_reason, p.failure_status)
 WHERE p.failure_kind IS NULL
   AND (p.failure_reason IS NOT NULL OR p.failure_status IS NOT NULL);

-- Surface the distribution so the migration reports what it actually did.
DO $$
DECLARE
  summary text;
BEGIN
  SELECT string_agg(format('%s=%s', failure_kind, total), ', ' ORDER BY total DESC)
    INTO summary
    FROM (
      SELECT failure_kind, count(*) AS total
        FROM public.payments
       WHERE failure_kind IS NOT NULL
       GROUP BY failure_kind
    ) AS kinds;

  IF summary IS NULL THEN
    RAISE NOTICE 'No recorded payment failures to classify.';
  ELSE
    RAISE NOTICE 'payments.failure_kind after backfill: %', summary;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 6. Verification (run manually after applying)
--
--   6a. Which failures have structured data now:
--
--     SELECT failure_kind, failure_source, count(*)
--       FROM public.payments
--      WHERE failure_kind IS NOT NULL
--      GROUP BY 1, 2
--      ORDER BY 3 DESC;
--
--   6b. Nothing completed may carry a failure (must return zero rows):
--
--     SELECT id, status, failure_kind, failure_reason
--       FROM public.payments
--      WHERE failure_kind IS NOT NULL
--        AND lower(coalesce(status, '')) IN ('completed', 'refunded');
--
--   6c. And nothing may have a half-written failure (must return zero rows):
--
--     SELECT id, failure_kind, failure_source, failure_at
--       FROM public.payments
--      WHERE (failure_kind IS NULL) <> (failure_source IS NULL);
-- ---------------------------------------------------------------------
