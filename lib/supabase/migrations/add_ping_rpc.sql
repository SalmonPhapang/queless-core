-- =============================================
-- PING RPC
-- Health-check function used by the app's
-- DatabaseTest (lib/utils/database_test.dart)
-- at startup. Missing previously, which made
-- the self-test log a 404 on every launch.
-- =============================================

create or replace function public.ping()
returns jsonb
language sql
stable
as $$
  select '{"ok": true, "pong": true}'::jsonb;
$$;

-- Allow the PostgREST API roles to call it
grant execute on function public.ping() to anon, authenticated;
revoke execute on function public.ping() from public;
