-- SUPERSEDED by 20260915_fix_alerts_trigger_rls.sql.
--
-- Why this file is no longer the fix:
--   * No timestamp prefix, so `supabase db push` never picked it up -- it only
--     took effect if applied by hand.
--   * SECURITY DEFINER alone does not bypass RLS unless the function is owned
--     by the owner of public.alerts (see section 2 of the new migration).
--   * The INSERT had no EXCEPTION guard, so any failure here aborted the whole
--     orders INSERT and broke checkout for every customer.
--
-- Kept only for history; apply 20260915_fix_alerts_trigger_rls.sql instead.
--
-- Original intent follows: allow order-created admin alerts to bypass
-- customer-session RLS without granting direct INSERT access to app users.

CREATE OR REPLACE FUNCTION public.create_order_alert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.alerts (alert_type, title, message, link, record_id)
  VALUES (
    'order',
    'New Order',
    'New order #' || COALESCE(NEW.order_number, 'Received'),
    '/orders',
    NEW.id::varchar
  );

  RETURN NEW;
END;
$function$;
