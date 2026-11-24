-- 20261124_000007_fix_driver_payment_pending_status.sql
--
-- Correction to 20261124_000006: driver_payments.status only allows
-- 'earned', 'pending_payout' and 'paid'. Use the existing ledger value.

CREATE OR REPLACE FUNCTION public.create_driver_payout_batches(
  p_cutoff timestamptz DEFAULT now()
)
RETURNS TABLE (result_payout_id uuid, result_driver_id uuid, result_amount numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  RETURN QUERY
  WITH locked AS (
    SELECT dp.id AS payment_id, dp.driver_id AS locked_driver_id, dp.amount AS locked_amount
    FROM public.driver_payments dp
    WHERE dp.status = 'earned'
      AND dp.payout_id IS NULL
      AND dp.created_at <= p_cutoff
    FOR UPDATE OF dp SKIP LOCKED
  ),
  grouped AS (
    SELECT
      l.locked_driver_id AS grouped_driver_id,
      sum(l.locked_amount) AS grouped_amount,
      min(dp.created_at) AS grouped_period_start,
      max(dp.created_at) AS grouped_period_end
    FROM locked l
    JOIN public.driver_payments dp ON dp.id = l.payment_id
    JOIN public.drivers d ON d.id = l.locked_driver_id
    WHERE NULLIF(btrim(coalesce(d.bank_details ->> 'account_holder', '')), '') IS NOT NULL
      AND NULLIF(btrim(coalesce(d.bank_details ->> 'account_number', '')), '') IS NOT NULL
      AND NULLIF(btrim(coalesce(d.bank_details ->> 'branch_code', '')), '') IS NOT NULL
    GROUP BY l.locked_driver_id
  ),
  inserted AS (
    INSERT INTO public.driver_payouts (
      driver_id,
      amount,
      status,
      bank_details,
      notes,
      period_start,
      period_end
    )
    SELECT
      g.grouped_driver_id,
      g.grouped_amount,
      'pending',
      d.bank_details,
      'Queless Tue/Thu batch',
      g.grouped_period_start,
      g.grouped_period_end
    FROM grouped g
    JOIN public.drivers d ON d.id = g.grouped_driver_id
    RETURNING public.driver_payouts.id AS inserted_id,
              public.driver_payouts.driver_id AS inserted_driver_id,
              public.driver_payouts.amount AS inserted_amount
  ),
  linked AS (
    UPDATE public.driver_payments dp
    SET payout_id = i.inserted_id,
        status = 'pending_payout',
        updated_at = now()
    FROM inserted i
    WHERE dp.driver_id = i.inserted_driver_id
      AND dp.status = 'earned'
      AND dp.payout_id IS NULL
      AND dp.created_at <= p_cutoff
      AND dp.id IN (SELECT l.payment_id FROM locked l)
    RETURNING dp.id AS linked_id
  )
  SELECT i.inserted_id, i.inserted_driver_id, i.inserted_amount
  FROM inserted i;
END
$fn$;

REVOKE ALL ON FUNCTION public.create_driver_payout_batches(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_driver_payout_batches(timestamptz) TO service_role;
