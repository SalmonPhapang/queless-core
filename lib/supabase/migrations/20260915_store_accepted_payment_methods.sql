-- 20260915_store_accepted_payment_methods.sql
--
-- Stores declare which payment methods they accept. The column already
-- exists (text[], default ARRAY['eft']); this migration makes the contract
-- explicit so a typo in the partner app can never silently disable payment
-- for a store.
--
-- Codes (must stay in sync with PaymentMethod.storeCode in
-- lib/models/payment.dart):
--   'eft'  -> Paystack checkout, offers card and instant EFT
--   'cash' -> Cash on Delivery, collected by the driver at the door
--
-- The customer app reads this via Store.acceptedPaymentMethods and renders
-- only the accepted options; unknown or empty values fall back to the
-- default (['eft']) on the client, and NOT NULL + the CHECK make that
-- fallback impossible to trigger from the database side.

BEGIN;

-- 1. Normalise existing values: dedupe elements.
UPDATE public.stores
   SET accepted_payment_methods =
         ARRAY(SELECT DISTINCT unnest(accepted_payment_methods))
 WHERE accepted_payment_methods IS NOT NULL;

-- 2. Backfill NULLs to the column default so NOT NULL is safe.
UPDATE public.stores
   SET accepted_payment_methods = ARRAY['eft'::text]
 WHERE accepted_payment_methods IS NULL;

-- 3. Pin the default and forbid NULL.
ALTER TABLE public.stores
  ALTER COLUMN accepted_payment_methods SET DEFAULT ARRAY['eft'::text],
  ALTER COLUMN accepted_payment_methods SET NOT NULL;

-- 4. Restrict values to the known set. <@ means "is a subset of", so any
--    unrecognised code (e.g. 'crd', 'Cash ') fails here — with a constraint
--    name that says why.
ALTER TABLE public.stores
  DROP CONSTRAINT IF EXISTS stores_accepted_payment_methods_valid;
ALTER TABLE public.stores
  ADD CONSTRAINT stores_accepted_payment_methods_valid
  CHECK (accepted_payment_methods <@ ARRAY['eft'::text, 'cash'::text]);

COMMENT ON COLUMN public.stores.accepted_payment_methods IS
  'Payment methods the store accepts: eft = Paystack (card/instant EFT), cash = cash on delivery. See PaymentMethod.storeCode.';

DO $$
DECLARE
  v_counts text;
BEGIN
  SELECT string_agg(method || ': ' || n, ', ')
    INTO v_counts
    FROM (
      SELECT COALESCE(array_to_string(accepted_payment_methods, '+'), 'null') AS method,
             count(*) AS n
      FROM public.stores
      GROUP BY 1
    ) s;
  RAISE NOTICE 'accepted_payment_methods distribution after migration: %', v_counts;
END $$;

COMMIT;

-- ============================================================
-- Verification (run after applying):
--
-- Every store must have at least one accepted method, all drawn
-- from the two known codes:
-- SELECT id, name, accepted_payment_methods
--   FROM public.stores
--  WHERE accepted_payment_methods IS NULL
--     OR cardinality(accepted_payment_methods) = 0
--     OR NOT (accepted_payment_methods <@ ARRAY['eft','cash']);
--  -> must return zero rows.
--
-- Stores accepting cash (sanity check for the checkout picker):
-- SELECT name, accepted_payment_methods FROM public.stores
--  WHERE 'cash' = ANY (accepted_payment_methods);
-- ============================================================
