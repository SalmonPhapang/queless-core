-- =====================================================================
-- Migration: 20260915_fix_alerts_trigger_rls
--
-- Symptom (observed live, blocks checkout completely):
--
--   failed to insert from orders:
--   new row violates row-level security policy for table "alerts"
--
-- What is actually happening:
--   1. The customer app inserts a row into public.orders as `authenticated`.
--      That is permitted -- `orders_insert_own` allows auth.uid() = user_id.
--   2. An AFTER INSERT trigger on public.orders then writes an ADMIN alert
--      into public.alerts (this is the partner/admin notification feed; the
--      table is not defined in this repo, it lives only in the live schema).
--   3. That trigger function runs as the CUSTOMER session, public.alerts has
--      RLS enabled, and no policy grants the customer INSERT -- so the insert
--      raised.
--   4. A trigger error aborts the whole statement, so ordering failed for
--      every customer. An internal admin side effect took down checkout.
--
-- Two independent defences are added below, because either one alone is
-- fragile:
--
--   A. create_order_alert() becomes SECURITY DEFINER and is owned by the
--      owner of public.alerts, so its INSERT is exempt from the customer's
--      RLS. This is the correct fix and keeps alerts readable only by admins.
--      If that exemption cannot apply (FORCE ROW LEVEL SECURITY, or the
--      owner change is refused), the migration adds ONE narrow policy instead:
--      an authenticated session may insert an 'order' alert for an order it
--      owns, and nothing else. It never grants a blanket INSERT on alerts.
--
--   B. The alert insert is wrapped in a nested BEGIN/EXCEPTION block. An
--      alert is a nice-to-have notification; it must never be able to stop a
--      paying customer's order. If the insert still fails for any reason
--      (FORCE RLS, missing column, extension gone), it now becomes a server
--      WARNING in the Postgres logs and the order is still created.
--
-- Supersedes the un-timestamped lib/supabase/migrations/fix_alerts_trigger_rls.sql,
-- which applied the SECURITY DEFINER half but could not be picked up by
-- `supabase db push` (no timestamp) and had no failure guard.
--
-- Safe to re-run: every statement is CREATE OR REPLACE / guarded.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The trigger function: privileged, search_path-pinned, non-fatal.
--
--    SECURITY DEFINER alone is not enough on its own -- it only helps if the
--    function's owner can bypass the policy (see section 2, which aligns the
--    owner with the alerts table). The nested exception block is the part
--    that guarantees a broken alerts setup can never block an order again.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order_alert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
-- Pin search_path: a SECURITY DEFINER function must never resolve
-- unqualified names through a caller-controlled search_path.
SET search_path = public, pg_catalog
AS $function$
BEGIN
  BEGIN
    INSERT INTO public.alerts (alert_type, title, message, link, record_id)
    VALUES (
      'order',
      'New Order',
      'New order #' || COALESCE(NEW.order_number, 'Received'),
      '/orders',
      NEW.id::varchar
    );
  EXCEPTION WHEN OTHERS THEN
    -- Swallow, but never silently: this shows up in the Postgres logs so a
    -- broken admin feed is visible without breaking the customer's order.
    RAISE WARNING
      'create_order_alert: alert skipped for order % (order_number=%): %',
      NEW.id, COALESCE(NEW.order_number, '<none>'), SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

-- Trigger functions are executed by whoever fired the DML, so keep EXECUTE
-- available to the app roles (mirrors queue_new_order_notification).
REVOKE ALL ON FUNCTION public.create_order_alert() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order_alert()
  TO postgres, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Align the function's owner with the alerts table, and report the
--    RLS posture so this migration tells you the real state of the DB.
--
--    Postgres exempts a table's OWNER from that table's RLS, so a
--    SECURITY DEFINER function owned by the alerts owner can insert freely.
--    (FORCE ROW LEVEL SECURITY removes that exemption -- detected below.)
-- ---------------------------------------------------------------------
DO $$
DECLARE
  alerts_owner      name;
  alerts_rls        boolean;
  alerts_force_rls  boolean;
  alerts_found      boolean := false;
  owner_aligned     boolean := false;
  record_id_type    text;
  record_id_match   text;
BEGIN
  SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
    INTO alerts_owner, alerts_rls, alerts_force_rls
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'alerts'
     AND c.relkind = 'r'
   LIMIT 1;

  alerts_found := FOUND;

  IF NOT alerts_found THEN
    RAISE WARNING
      'public.alerts does not exist (or is not a table) -- nothing to align. '
      'If order alerts live in another schema, apply the same owner/permission '
      'treatment to create_order_alert() there.';
    RETURN;
  END IF;

  RAISE NOTICE
    'public.alerts: owner=%, rls_enabled=%, force_rls=%',
    alerts_owner, alerts_rls, alerts_force_rls;

  BEGIN
    EXECUTE format(
      'ALTER FUNCTION public.create_order_alert() OWNER TO %I',
      alerts_owner
    );
    owner_aligned := true;
    RAISE NOTICE
      'create_order_alert() owner set to % (RLS exempt as table owner)',
      alerts_owner;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'Could not set create_order_alert() owner to % (%). Falling back to the '
      'narrow policy below so order alerts still get recorded.',
      alerts_owner, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- Fallback: table ownership only bypasses RLS when the table does not
  -- use FORCE ROW LEVEL SECURITY. If it does (or the owner change was
  -- refused), grant the least the trigger actually needs -- an
  -- authenticated session may create an 'order' alert for an order it
  -- owns, and nothing else. No blanket INSERT on alerts is ever granted.
  -- ------------------------------------------------------------------
  IF alerts_rls AND (alerts_force_rls OR NOT owner_aligned) THEN
    SELECT data_type
      INTO record_id_type
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'alerts'
       AND column_name  = 'record_id';

    IF record_id_type = 'uuid' THEN
      record_id_match := 'o.id = alerts.record_id';
    ELSIF record_id_type IS NOT NULL THEN
      record_id_match := 'o.id::text = alerts.record_id::text';
    END IF;

    IF record_id_match IS NULL THEN
      RAISE WARNING
        'Could not build the alerts fallback policy (record_id column type is %). '
        'Order alerts will be skipped; order creation is unaffected.',
        coalesce(record_id_type, '<missing>');
    ELSE
      EXECUTE 'DROP POLICY IF EXISTS alerts_insert_own_order ON public.alerts';
      EXECUTE format(
        'CREATE POLICY alerts_insert_own_order ON public.alerts '
        'FOR INSERT TO authenticated '
        'WITH CHECK ('
        '  alert_type = ''order'' '
        '  AND EXISTS (SELECT 1 FROM public.orders o '
        '               WHERE o.user_id = auth.uid() AND %s)'
        ')',
        record_id_match
      );
      RAISE NOTICE
        'Created policy alerts_insert_own_order on public.alerts (own order only).';
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 3. Harden EVERY other trigger function on public.orders that writes to
--    alerts.
--
--    The live schema may not route this through create_order_alert() -- the
--    trigger could call any function name. Rather than guess, find them by
--    inspecting the function bodies, then apply the same treatment. Anything
--    we cannot patch is reported so it can be fixed by hand instead of
--    failing silently.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  alerts_owner name;
  fn           record;
  fn_guarded   boolean;
  patched      integer := 0;
BEGIN
  SELECT pg_get_userbyid(c.relowner)
    INTO alerts_owner
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'alerts' AND c.relkind = 'r'
   LIMIT 1;

  FOR fn IN
    SELECT DISTINCT
           p.oid,
           p.oid::regprocedure::text AS ident,
           p.prosecdef               AS is_security_definer,
           p.proconfig               AS config
      FROM pg_trigger t
      JOIN pg_class     c  ON c.oid  = t.tgrelid
      JOIN pg_namespace cn ON cn.oid = c.relnamespace
      JOIN pg_proc      p  ON p.oid  = t.tgfoid
     WHERE NOT t.tgisinternal
       AND cn.nspname = 'public'
       AND c.relname  = 'orders'
       AND p.prokind  = 'f'
       -- Two separate tests rather than one regex: it does not matter how the
       -- body is formatted or where the line breaks fall.
       AND p.prosrc ~* 'insert[[:space:]]+into'
       AND p.prosrc ~* 'alerts'
  LOOP
    patched := patched + 1;

    IF fn.is_security_definer THEN
      RAISE NOTICE '% already SECURITY DEFINER', fn.ident;
    ELSE
      BEGIN
        EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER', fn.ident);
        RAISE NOTICE '% marked SECURITY DEFINER', fn.ident;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Could not mark % SECURITY DEFINER: %', fn.ident, SQLERRM;
      END;
    END IF;

    BEGIN
      EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_catalog', fn.ident);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Could not pin search_path on %: %', fn.ident, SQLERRM;
    END;

    IF alerts_owner IS NOT NULL THEN
      BEGIN
        EXECUTE format('ALTER FUNCTION %s OWNER TO %I', fn.ident, alerts_owner);
        RAISE NOTICE '% owner set to %', fn.ident, alerts_owner;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
          'Could not set % owner to %: %. Alerts from this function may be skipped; '
          'order creation is unaffected only if the body guards its own insert.',
          fn.ident, alerts_owner, SQLERRM;
      END;
    END IF;

    -- A patched function that does NOT guard its own INSERT can still abort an
    -- order if anything else goes wrong in it. Flag it for a follow-up.
    SELECT prosrc ~* 'exception[[:space:]]+when'
      INTO fn_guarded
      FROM pg_proc
     WHERE oid = fn.oid;

    IF NOT coalesce(fn_guarded, true) THEN
      RAISE WARNING
        '% inserts into alerts without an EXCEPTION guard: it can still fail the '
        'customer''s order. Wrap its alerts INSERT in BEGIN ... EXCEPTION WHEN OTHERS THEN '
        'RAISE WARNING ..., or fold it into public.create_order_alert().',
        fn.ident;
    END IF;
  END LOOP;

  IF patched = 0 THEN
    RAISE NOTICE
      'No trigger function on public.orders writes to alerts -- nothing to patch. '
      'If the error persists, re-check which table/trigger produced it.';
  ELSE
    RAISE NOTICE 'Reviewed % alert-writing trigger function(s) on public.orders.', patched;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4. Verification (run manually after applying)
--
--   4a. Confirm the function is privileged and its search_path is pinned:
--
--     SELECT p.oid::regprocedure::text AS function,
--            p.prosecdef              AS security_definer,
--            p.proconfig              AS settings,
--            pg_get_userbyid(p.proowner) AS owner
--       FROM pg_proc p
--      WHERE p.proname = 'create_order_alert';
--
--   4b. Confirm who owns alerts and whether it is RLS-protected:
--
--     SELECT pg_get_userbyid(c.relowner) AS owner,
--            c.relrowsecurity            AS rls_enabled,
--            c.relforcerowsecurity       AS force_rls
--       FROM pg_class c
--       JOIN pg_namespace n ON n.oid = c.relnamespace
--      WHERE n.nspname = 'public' AND c.relname = 'alerts';
--
--   4c. End-to-end: create a real order as a customer (this is the check that
--       was failing). Substitute a real user_id / store_id, and note the
--       transaction is rolled back so nothing is left behind:
--
--     BEGIN;
--       INSERT INTO public.orders (user_id, store_id, payment_method, total, items)
--       VALUES ('<user uuid>', '<store uuid>', 'Card', 135.00, '[]'::jsonb)
--       RETURNING order_number, payment_method, status;
--
--       SELECT * FROM public.alerts ORDER BY created_at DESC LIMIT 1;
--     ROLLBACK;
--
--   Expect: a QLE-... order number, payment_method 'Card', and one alert row.
--   If the order inserts but no alert row appears, read the server logs for a
--   'create_order_alert: alert skipped' WARNING and apply the policy or owner
--   change it names.
-- ---------------------------------------------------------------------
