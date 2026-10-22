-- ============================================================
-- ENABLE REALTIME FOR NOTIFICATIONS
-- supabase_flutter's `.stream()` subscriptions only receive
-- change events for tables added to the supabase_realtime
-- publication. Without this, the in-app inbox would only
-- refresh on pull-to-refresh.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
