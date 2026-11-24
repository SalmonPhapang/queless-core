-- 20261124_000010_fix_driver_payout_pause_resume.sql
--
-- Correction to 20261124_000009: cron.job is not directly writable by the
-- SECURITY DEFINER function owner. Use cron.alter_job instead.

CREATE OR REPLACE FUNCTION public.set_driver_payout_schedule_active(
  p_active boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $fn$
DECLARE
  v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid
  FROM cron.job
  WHERE jobname = 'driver-payouts-tue-thu';

  IF v_jobid IS NULL THEN
    RAISE EXCEPTION 'driver payout cron job not found';
  END IF;

  PERFORM cron.alter_job(job_id => v_jobid, active => p_active);

  RETURN p_active;
END
$fn$;

REVOKE ALL ON FUNCTION public.set_driver_payout_schedule_active(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_driver_payout_schedule_active(boolean) TO service_role;
