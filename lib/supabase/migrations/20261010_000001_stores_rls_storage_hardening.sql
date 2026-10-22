-- ===========================================================================
-- Store onboarding / store profile hardening
-- Date: 2026-10-10
--
-- Context (verified against production project lxsvydiyzeavdqbjxkpp):
--   * public.stores had three policies with `qual = true` / `with_check = true`
--     for the `authenticated` role:
--       - "Allow authenticated users to insert stores"
--       - "Allow authenticated users to update stores"
--       - "Allow authenticated users to delete stores"
--     Because permissive policies are OR'd, ANY signed-in user could update or
--     delete ANY store: set is_approved = true (self-approve), rewrite owner_id
--     (take over another owner's store) or delete it outright.
--   * Storage bucket `stores` (public) had no storage.objects policies at all,
--     so the app's logo upload was rejected by RLS. The wizard swallowed that
--     error, so onboarding "succeeded" without a logo.
--
-- Design:
--   * Store ownership is `stores.owner_id -> auth.users.id` (unchanged).
--   * Store sessions get owner-scoped write access.
--   * Queless operators keep write access through an explicit admin identity
--     (public.drivers.role_type = 'admin'); service-role/dashboard connections
--     bypass RLS and are unaffected.
--   * Approval/ownership columns are frozen for store sessions by a trigger, so
--     the invariant holds even if a policy is ever loosened again.
--
-- Rollback is at the bottom of this file.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Platform-admin predicate
-- ---------------------------------------------------------------------------
create or replace function public.is_platform_admin(p_user uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_user is not null
     and exists (
           select 1
             from public.drivers d
            where d.user_id = p_user
              and d.role_type = 'admin'
         );
$$;

comment on function public.is_platform_admin(uuid) is
  'True when the given user (default: auth.uid()) is a Queless operator, identified by public.drivers.role_type = ''admin''. SECURITY DEFINER so the check works regardless of drivers RLS. Returns false for service-role/dashboard connections (no JWT subject).';

revoke all on function public.is_platform_admin(uuid) from public;
grant execute on function public.is_platform_admin(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Remove the over-permissive store write policies
-- ---------------------------------------------------------------------------
drop policy if exists "Allow authenticated users to insert stores" on public.stores;
drop policy if exists "Allow authenticated users to update stores" on public.stores;
drop policy if exists "Allow authenticated users to delete stores" on public.stores;

-- The pre-existing owner policy had no WITH CHECK, so an owner could still have
-- moved a store to another user; replace it with a symmetric one.
drop policy if exists "Store owners can update their stores" on public.stores;
drop policy if exists "Authenticated users can create stores" on public.stores;

-- ---------------------------------------------------------------------------
-- 3. Owner-scoped (plus operator) write policies
-- ---------------------------------------------------------------------------
create policy "Store owners can create their store"
  on public.stores
  for insert
  to authenticated
  with check (auth.uid() = owner_id or public.is_platform_admin());

create policy "Store owners can update their store"
  on public.stores
  for update
  to authenticated
  using (auth.uid() = owner_id or public.is_platform_admin())
  with check (auth.uid() = owner_id or public.is_platform_admin());

create policy "Store owners can delete their store"
  on public.stores
  for delete
  to authenticated
  using (auth.uid() = owner_id or public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 4. Freeze approval / ownership columns for store sessions
-- ---------------------------------------------------------------------------
create or replace function public.stores_guard_privileged_columns()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Service-role and dashboard connections have no JWT subject; Queless
  -- operations run there and must keep working. Platform admins may also
  -- approve stores deliberately.
  if auth.uid() is null or public.is_platform_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if coalesce(new.is_approved, false) then
      raise exception 'A store created from the store app starts unapproved'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.is_approved is distinct from old.is_approved then
    raise exception 'is_approved can only be changed by Queless operations'
      using errcode = '42501';
  end if;

  if new.owner_id is distinct from old.owner_id then
    raise exception 'A store cannot be transferred to another owner from the store app'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_stores_guard_privileged_columns on public.stores;
create trigger trg_stores_guard_privileged_columns
  before insert or update on public.stores
  for each row
  execute function public.stores_guard_privileged_columns();

-- ---------------------------------------------------------------------------
-- 5. Storage policies for the `stores` bucket (logo upload)
-- ---------------------------------------------------------------------------
-- The app uploads to "{auth.uid()}_{timestamp}.{ext}" at the bucket root, so
-- each object is scoped to the uploader's own user id. Queless operators can
-- also manage the bucket (legacy "store_images/..." objects come from the admin
-- tooling); service-role connections bypass these policies entirely.
create policy "Store owners can upload store images"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'stores'
    and (
      public.is_platform_admin()
      or name like auth.uid()::text || '\_%'
    )
  );

create policy "Store owners can replace store images"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'stores'
    and (
      public.is_platform_admin()
      or name like auth.uid()::text || '\_%'
    )
  )
  with check (
    bucket_id = 'stores'
    and (
      public.is_platform_admin()
      or name like auth.uid()::text || '\_%'
    )
  );

create policy "Store owners can delete store images"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'stores'
    and (
      public.is_platform_admin()
      or name like auth.uid()::text || '\_%'
    )
  );

-- The bucket is public; this keeps the storage API (signed URLs, list) readable
-- for the same objects a public URL already exposes.
create policy "Store images are publicly readable"
  on storage.objects
  for select
  to public
  using (bucket_id = 'stores');

-- ===========================================================================
-- ROLLBACK (run manually to revert)
-- ===========================================================================
-- drop policy if exists "Store owners can create their store" on public.stores;
-- drop policy if exists "Store owners can update their store" on public.stores;
-- drop policy if exists "Store owners can delete their store" on public.stores;
-- create policy "Authenticated users can create stores" on public.stores
--   for insert to public with check (auth.uid() = owner_id);
-- create policy "Store owners can update their stores" on public.stores
--   for update to public using (auth.uid() = owner_id);
-- create policy "Allow authenticated users to insert stores" on public.stores
--   for insert to authenticated with check (true);
-- create policy "Allow authenticated users to update stores" on public.stores
--   for update to authenticated using (true) with check (true);
-- create policy "Allow authenticated users to delete stores" on public.stores
--   for delete to authenticated using (true);
-- drop trigger if exists trg_stores_guard_privileged_columns on public.stores;
-- drop function if exists public.stores_guard_privileged_columns();
-- drop policy if exists "Store owners can upload store images" on storage.objects;
-- drop policy if exists "Store owners can replace store images" on storage.objects;
-- drop policy if exists "Store owners can delete store images" on storage.objects;
-- drop policy if exists "Store images are publicly readable" on storage.objects;
-- drop function if exists public.is_platform_admin(uuid);
