-- ===========================================================================
-- Restrict public.is_platform_admin(uuid) EXECUTE
-- Date: 2026-10-10
--
-- is_platform_admin() is only evaluated by signed-in store sessions (all store
-- and storage policies that use it are `TO authenticated`) and by service_role.
-- Supabase grants EXECUTE on new functions to PUBLIC by default, which left it
-- callable by `anon` via /rest/v1/rpc/is_platform_admin — signed-out clients
-- could probe whether a given user id is a Queless operator.
--
-- Files 20261010_000001_stores_rls_storage_hardening.sql and this one are both
-- applied to project lxsvydiyzeavdqbjxkpp.
-- ===========================================================================

revoke execute on function public.is_platform_admin(uuid) from anon, public;
grant execute on function public.is_platform_admin(uuid) to authenticated, service_role;

-- ROLLBACK (run manually to revert)
-- grant execute on function public.is_platform_admin(uuid) to anon;
