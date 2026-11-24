-- 20261124_000009_driver_payout_pause_resume.sql
--
-- Simple on/off switch for the Tuesday/Thursday payout cron job while the
-- payment flow is being tested.

CREATE OR REPLACE FUNCTION public.set_driver_payout_schedule_active(
  p_active boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $fn$
DECLARE
  v_active boolean;
BEGIN
  UPDATE cron.job
  SET active = p_active
  WHERE jobname = 'driver-payouts-tue-thu'
  RETURNING active INTO v_active;

  IF v_active IS NULL THEN
    RAISE EXCEPTION 'driver payout cron job not found';
  END IF;

  RETURN v_active;
END
$fn$;

REVOKE ALL ON FUNCTION public.set_driver_payout_schedule_active(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_driver_payout_schedule_active(boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.get_driver_payout_schedule_active()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = cron
AS $fn$
  SELECT active
  FROM cron.job
  WHERE jobname = 'driver-payouts-tue-thu'
$fn$;

REVOKE ALL ON FUNCTION public.get_driver_payout_schedule_active() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_payout_schedule_active() TO service_role;
