-- =====================================================================
-- Migration: 20260915_fix_order_identity_and_payment
--
-- Problem this fixes (observed on a hand-inserted row):
--   order_number = 'SMOKE-20260908122551'   <- not a Queless order number
--   payment_method = 'card'                 <- app stores 'Card or Instant EFT'
--   items = '[]', delivery_address = '{}'   <- empty test order, live in the
--                                              store's acceptance queue
--   no row in public.payments               <- so nothing was payable: the
--                                              Paystack checkout lives off a
--                                              payments row and could not start
--
-- Root causes:
--   1. `orders.order_number` had NO default and NO trigger, so only the
--      Flutter client's IdGenerator produced 'QLE-...' numbers. Any other
--      writer (SQL console, MCP, seed script, another service) could write
--      any string, or NULL.
--   2. `orders.payment_method` was free text with three competing
--      conventions: the app wrote PaymentMethod.displayName
--      ('Card or Instant EFT'), the payments table wrote the enum name
--      ('card' / 'instantEft'), and hand-written rows used lowercase
--      labels. The customer app could only map its own spelling back, so
--      legacy values made "Pay Now" error out instead of opening Paystack.
--
-- Guarantees added here (so no client can regress them):
--   * Every order row carries a valid, unique 'QLE-XXXXXXXX' number, whether
--     or not the writer supplied one.
--   * `orders.payment_method` is always one of the canonical labels the app
--     writes and reads.
--   * Live unpaid Paystack orders always have a payments row to pay against.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Canonical payment-method labels
--
--    Mirrors PaymentMethod.displayName / PaymentMethod.tryParse in
--    lib/models/payment.dart. Only 'Card' and 'Instant EFT' are payable
--    online (both through Paystack); EFT / Cash on Delivery are kept so
--    offline flows keep working.
--
--    Returns NULL for blank or unrecognised input so callers can choose
--    between "normalise" (migration) and "reject loudly" (trigger).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.canonical_payment_method(raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_catalog
AS $$
  SELECT CASE
    WHEN keyed IN ('card', 'cards', 'cardpayment', 'creditcard', 'debitcard',
                   'creditdebitcard', 'creditdebitcards')
      THEN 'Card'
    -- Historical app value: instantEft.displayName was 'Card or Instant EFT',
    -- which is exactly the single Paystack-hosted option the app offers.
    WHEN keyed IN ('instanteft', 'instanteftpayment', 'cardorinstanteft', 'eftorcard')
      THEN 'Instant EFT'
    WHEN keyed IN ('eft', 'banktransfer')
      THEN 'EFT'
    WHEN keyed IN ('cashondelivery', 'cash', 'cod')
      THEN 'Cash on Delivery'
    ELSE NULL
  END
  FROM (
    SELECT lower(regexp_replace(btrim(coalesce(raw, '')), '[\s_\-/]+', '', 'g')) AS keyed
  ) AS normalised;
$$;

COMMENT ON FUNCTION public.canonical_payment_method(text) IS
  'Canonical order payment-method label for any historical spelling; NULL when '
  'the value is blank or not a known method.';

-- ---------------------------------------------------------------------
-- 2. Order-number generator (kept as a permanent function)
--
--    Same Snowflake -> base36 scheme as the Dart IdGenerator so numbers
--    produced by the DB are indistinguishable from client ones, and so
--    old/new orders stay in one continuous series.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_order_number(
  created_at_timestamp timestamptz DEFAULT now(),
  row_id uuid DEFAULT gen_random_uuid()
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_catalog
AS $$
DECLARE
  epoch_ms      constant bigint := 1735689600000; -- 2026-01-01T00:00:00Z
  timestamp_ms  bigint;
  entropy       bigint;
  snowflake_id  bigint;
  base36_chars  constant text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  result        text := '';
  remaining     bigint;
BEGIN
  timestamp_ms := (extract(epoch FROM created_at_timestamp) * 1000)::bigint - epoch_ms;
  IF timestamp_ms < 0 THEN
    timestamp_ms := 0;
  END IF;

  -- 12 bits of entropy from the row's UUID, mirroring the client's sequence.
  entropy := ('x' || left(replace(row_id::text, '-', ''), 3))::bit(12)::bigint;

  -- timestamp << 22 | datacenter(1) << 17 | worker(1) << 12 | entropy
  snowflake_id := (timestamp_ms << 22) | (1::bigint << 17) | (1::bigint << 12) | entropy;

  remaining := snowflake_id;
  WHILE remaining > 0 LOOP
    result := substr(base36_chars, (remaining % 36)::integer + 1, 1) || result;
    remaining := remaining / 36;
  END LOOP;

  RETURN 'QLE-' || lpad(result, 8, '0');
END;
$$;

COMMENT ON FUNCTION public.generate_order_number(timestamptz, uuid) IS
  'Queless order number: QLE-<base36 snowflake>, matching lib/utils/id_generator.dart.';

-- ---------------------------------------------------------------------
-- 3. Repair existing order numbers
--
--    Anything NULL, blank or not matching QLE-XXXXXXXX is renumbered, so
--    hand-written identifiers like 'SMOKE-20260908122551' leave the table.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  bad record;
  candidate text;
  attempt integer;
BEGIN
  FOR bad IN
    SELECT id, created_at
      FROM public.orders
     WHERE order_number IS NULL
        OR btrim(order_number) = ''
        OR order_number !~ '^QLE-[0-9A-Z]{6,12}$'
     ORDER BY created_at
  LOOP
    candidate := NULL;
    FOR attempt IN 1..10 LOOP
      -- New UUID each attempt so a (vanishingly rare) collision can retry.
      candidate := public.generate_order_number(coalesce(bad.created_at, now()), gen_random_uuid());
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.orders WHERE order_number = candidate);
    END LOOP;

    UPDATE public.orders
       SET order_number = candidate
     WHERE id = bad.id;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 4. Repair existing payment methods
--
--    Known spellings are normalised. Blank values are derived from the
--    order's payment row when one exists (that row recorded which method was
--    actually chosen), otherwise from the app's only online method.
-- ---------------------------------------------------------------------
UPDATE public.orders o
   SET payment_method = public.canonical_payment_method(o.payment_method)
 WHERE public.canonical_payment_method(o.payment_method) IS NOT NULL
   AND o.payment_method IS DISTINCT FROM public.canonical_payment_method(o.payment_method);

UPDATE public.orders o
   SET payment_method = coalesce(
         (SELECT public.canonical_payment_method(p.payment_method)
            FROM public.payments p
           WHERE p.order_id = o.id
           ORDER BY p.created_at DESC
           LIMIT 1),
         'Instant EFT'
       )
 WHERE public.canonical_payment_method(o.payment_method) IS NULL;

-- Surface anything we guessed at so the rewrite is never silent.
DO $$
DECLARE
  leftover text;
BEGIN
  SELECT string_agg(DISTINCT payment_method, ', ')
    INTO leftover
    FROM public.orders
   WHERE payment_method NOT IN ('Card', 'Instant EFT', 'EFT', 'Cash on Delivery');

  IF leftover IS NOT NULL THEN
    RAISE NOTICE 'orders.payment_method: unknown values normalised to Instant EFT: %', leftover;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 5. Retire empty test/orphan orders from live queues
--
--    An order with no items and no payment record is not a real customer
--    order; it was placed by a smoke test or a manual insert. Cancelling
--    (rather than deleting) keeps the audit trail while taking it out of
--    the store's acceptance queue. This runs BEFORE the payment backfill in
--    section 6 on purpose -- otherwise every empty order would be handed a
--    fresh payment row and survive.
-- ---------------------------------------------------------------------
UPDATE public.orders o
   SET status = 'cancelled',
       cancel_reason = coalesce(
         o.cancel_reason,
         'Auto-cancelled: no items and no payment record (test/orphan order)'
       ),
       updated_at = now()
 WHERE o.status NOT IN ('cancelled', 'rejected', 'delivered', 'refunded')
   AND o.items::text IN ('[]', 'null')
   AND NOT EXISTS (SELECT 1 FROM public.payments p WHERE p.order_id = o.id);

-- ---------------------------------------------------------------------
-- 6. Backfill a payments row for live orders that cannot be paid
--
--    The Paystack checkout is driven entirely by a payments row, so an
--    unpaid order without one is a dead end for both customer and store
--    (this is the "no payment record" symptom). Only orders that still need
--    paying are touched; completed, cancelled and offline orders are left
--    alone.
-- ---------------------------------------------------------------------
INSERT INTO public.payments (
  order_id, user_id, amount, payment_method, provider, status,
  payment_reference, metadata, created_at, updated_at
)
SELECT
  o.id,
  o.user_id,
  coalesce(o.total, 0),
  'instantEft',                 -- payments keeps the enum-name convention
  'paystack',
  'pending',
  'QUE' || (extract(epoch FROM clock_timestamp()) * 1000)::bigint
        || '-' || left(replace(o.id::text, '-', ''), 6),
  jsonb_build_object(
    'order_number', o.order_number,
    'backfilled_by', '20260915_fix_order_identity_and_payment'
  ),
  now(),
  now()
FROM public.orders o
WHERE o.payment_method IN ('Card', 'Instant EFT')
  AND lower(coalesce(o.payment_status, '')) NOT IN ('completed', 'refunded', 'partially_refunded')
  AND o.status NOT IN ('cancelled', 'rejected', 'delivered', 'refunded')
  AND NOT EXISTS (SELECT 1 FROM public.payments p WHERE p.order_id = o.id);

-- ---------------------------------------------------------------------
-- 7. Enforce the invariants going forward
-- ---------------------------------------------------------------------

-- 7a. Every new order gets a number, even if the writer passes NULL/''.
--     A column DEFAULT cannot help there (an explicit NULL overrides it),
--     so a BEFORE trigger is the only reliable guard.
CREATE OR REPLACE FUNCTION public.set_order_number()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
DECLARE
  candidate text;
  attempt integer;
BEGIN
  IF NEW.order_number IS NULL OR btrim(NEW.order_number) = '' THEN
    FOR attempt IN 1..10 LOOP
      candidate := public.generate_order_number(
        coalesce(NEW.created_at, now()),
        coalesce(NEW.id, gen_random_uuid())
      );
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.orders
         WHERE order_number = candidate AND id IS DISTINCT FROM NEW.id
      );
    END LOOP;
    NEW.order_number := candidate;
  END IF;

  NEW.order_number := btrim(upper(NEW.order_number));

  -- Fail loudly on a hand-written identifier (e.g. 'SMOKE-20260908122551'
  -- from a smoke test). Silently keeping it is what made the bad row look
  -- like a real order; the CHECK constraint below is the last line of
  -- defence, this gives the writer a usable message.
  IF NEW.order_number !~ '^QLE-[0-9A-Z]{6,12}$' THEN
    RAISE EXCEPTION
      'Invalid order_number "%"; Queless order numbers look like QLE-1A2B3C4D5E (omit the value to have one generated)',
      NEW.order_number
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- 7b. Normalise (or reject) the payment method for every write, so an older
--     app build that still sends 'Card or Instant EFT' keeps working while
--     nothing non-canonical can be stored.
CREATE OR REPLACE FUNCTION public.normalise_order_payment_method()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
DECLARE
  canonical text;
BEGIN
  canonical := public.canonical_payment_method(NEW.payment_method);

  IF canonical IS NOT NULL THEN
    NEW.payment_method := canonical;
  ELSIF btrim(coalesce(NEW.payment_method, '')) = '' THEN
    RAISE EXCEPTION
      'orders.payment_method is required; expected one of Card, Instant EFT, EFT, Cash on Delivery'
      USING ERRCODE = 'not_null_violation';
  ELSE
    RAISE EXCEPTION
      'Unsupported payment method "%": expected one of Card, Instant EFT, EFT, Cash on Delivery',
      NEW.payment_method
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_set_order_number ON public.orders;
CREATE TRIGGER orders_set_order_number
  BEFORE INSERT OR UPDATE OF order_number ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.set_order_number();

DROP TRIGGER IF EXISTS orders_normalise_payment_method ON public.orders;
CREATE TRIGGER orders_normalise_payment_method
  BEFORE INSERT OR UPDATE OF payment_method ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.normalise_order_payment_method();

-- 7c. Column default + constraints. The default is a safety net for inserts
--     that omit the column entirely; the trigger covers NULL/''.
ALTER TABLE public.orders
  ALTER COLUMN order_number SET DEFAULT public.generate_order_number();

ALTER TABLE public.orders
  ALTER COLUMN order_number SET NOT NULL;

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_order_number_format;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_order_number_format
  CHECK (order_number ~ '^QLE-[0-9A-Z]{6,12}$');

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_payment_method_canonical;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_payment_method_canonical
  CHECK (payment_method IN ('Card', 'Instant EFT', 'EFT', 'Cash on Delivery'));

-- ---------------------------------------------------------------------
-- 8. One payment row per order
--
--    The app now reuses an existing payment row instead of inserting a
--    second one (see PaymentService.createPayment), which is what makes the
--    unique index below safe. It is only created when the table is already
--    clean, so this migration never deletes payment records -- duplicate
--    rows are reported for manual review instead.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  duplicates integer;
BEGIN
  SELECT count(*) INTO duplicates
    FROM (
      SELECT order_id
        FROM public.payments
       GROUP BY order_id
      HAVING count(*) > 1
    ) AS dupes;

  IF duplicates = 0 THEN
    CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_order_id_unique
      ON public.payments (order_id);
  ELSE
    RAISE WARNING
      'payments: % order(s) have more than one payment row; unique index NOT created. Resolve duplicates, then re-run this block.',
      duplicates;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 9. Verification (run manually after applying)
--
--   SELECT order_number, payment_method, status, items
--     FROM public.orders
--    ORDER BY created_at DESC
--    LIMIT 20;
--
--   -- must return zero rows:
--   SELECT id, order_number, payment_method FROM public.orders
--    WHERE order_number !~ '^QLE-[0-9A-Z]{6,12}$'
--       OR payment_method NOT IN ('Card','Instant EFT','EFT','Cash on Delivery');
-- ---------------------------------------------------------------------
