-- 20261124_000005_driver_payout_tue_thu.sql
--
-- Driver payout batches run every Tuesday and Thursday at 15:00 SAST.
-- The cutoff for a run is 12:00 SAST, so an order delivered after noon goes
-- into the next run. Payouts are batched per driver, which keeps the Paystack
-- transfer fee from consuming individual delivery fees.

ALTER TABLE public.driver_payouts
  ADD COLUMN IF NOT EXISTS period_start timestamptz,
  ADD COLUMN IF NOT EXISTS period_end timestamptz,
  ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_error text;

CREATE INDEX IF NOT EXISTS idx_driver_payouts_scheduled_pending
  ON public.driver_payouts (status, created_at)
  WHERE status = 'pending';

-- Shared secret for the pg_cron -> Edge Function call. Generated in the
-- database so it is never printed or stored in application env files.
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name = 'driver_payout_cron_secret'
  ) THEN
    PERFORM vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'driver_payout_cron_secret',
      'Shared secret for the Tuesday/Thursday driver payout cron job'
    );
  END IF;
END
$do$;

-- Readable only by service_role, so the Edge Function can verify cron calls
-- without exposing the secret to clients.
CREATE OR REPLACE FUNCTION public.get_driver_payout_cron_secret()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = vault, public
AS $fn$
  SELECT decrypted_secret
  FROM vault.decrypted_secrets
  WHERE name = 'driver_payout_cron_secret'
$fn$;

REVOKE ALL ON FUNCTION public.get_driver_payout_cron_secret() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_payout_cron_secret() TO service_role;

-- Create one pending payout per driver for all earned deliveries at or before
-- p_cutoff. Drivers without usable bank details are skipped; their payments
-- stay "earned" and are picked up on a later run once details are added.
CREATE OR REPLACE FUNCTION public.create_driver_payout_batches(
  p_cutoff timestamptz DEFAULT now()
)
RETURNS TABLE (payout_id uuid, driver_id uuid, amount numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  RETURN QUERY
  WITH locked AS (
    SELECT dp.id, dp.driver_id, dp.amount, dp.created_at
    FROM public.driver_payments dp
    WHERE dp.status = 'earned'
      AND dp.payout_id IS NULL
      AND dp.created_at <= p_cutoff
    FOR UPDATE OF dp SKIP LOCKED
  ),
  grouped AS (
    SELECT
      l.driver_id,
      sum(l.amount) AS amount,
      min(l.created_at) AS period_start,
      max(l.created_at) AS period_end
    FROM locked l
    JOIN public.drivers d ON d.id = l.driver_id
    WHERE NULLIF(btrim(coalesce(d.bank_details ->> 'account_holder', '')), '') IS NOT NULL
      AND NULLIF(btrim(coalesce(d.bank_details ->> 'account_number', '')), '') IS NOT NULL
      AND NULLIF(btrim(coalesce(d.bank_details ->> 'branch_code', '')), '') IS NOT NULL
    GROUP BY l.driver_id
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
      g.driver_id,
      g.amount,
      'pending',
      d.bank_details,
      'Queless Tue/Thu batch',
      g.period_start,
      g.period_end
    FROM grouped g
    JOIN public.drivers d ON d.id = g.driver_id
    RETURNING id, driver_id, amount
  ),
  linked AS (
    UPDATE public.driver_payments dp
    SET payout_id = i.id,
        status = 'pending',
        updated_at = now()
    FROM inserted i
    WHERE dp.driver_id = i.driver_id
      AND dp.status = 'earned'
      AND dp.payout_id IS NULL
      AND dp.created_at <= p_cutoff
      AND dp.id IN (SELECT id FROM locked)
    RETURNING dp.id
  )
  SELECT i.id, i.driver_id, i.amount
  FROM inserted i;
END
$fn$;

REVOKE ALL ON FUNCTION public.create_driver_payout_batches(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_driver_payout_batches(timestamptz) TO service_role;

-- 15:00 SAST is 13:00 UTC on the same day. Tuesday = 2, Thursday = 4.
-- The Edge Function receives a 3-hour lookback, which is the 12:00 SAST cutoff.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'driver-payouts-tue-thu') THEN
    PERFORM cron.unschedule('driver-payouts-tue-thu');
  END IF;

  PERFORM cron.schedule(
    'driver-payouts-tue-thu',
    '0 13 * * 2,4',
    $cmd$
    SELECT net.http_post(
      url := 'https://lxsvydiyzeavdqbjxkpp.supabase.co/functions/v1/driver-payouts-run',
      body := jsonb_build_object('cutoff_hours_ago', 3),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'driver_payout_cron_secret'
        )
      ),
      timeout_milliseconds := 30000
    )
    $cmd$
  );
END
$do$;
