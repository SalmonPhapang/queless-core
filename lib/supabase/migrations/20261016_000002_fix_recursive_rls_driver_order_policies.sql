-- ============================================================================
-- Break the drivers <-> driver_assignments <-> orders <-> users RLS recursion
-- ============================================================================
-- Symptom (live, reproduced as the `authenticated` role):
--
--   select * from public.users where id = auth.uid();
--   ERROR: 42P17: infinite recursion detected in policy for relation "drivers"
--
-- This broke the post-sign-in profile read in the customer and driver apps
-- (SupabaseService.selectSingle('users') / SupabaseAuthManager._loadUserData)
-- for every signed-in user, because the cycle was reachable from `users`:
--
--   users.drivers_can_read_customers            -> reads drivers
--   drivers.customers_read_assigned_driver      -> reads driver_assignments, orders
--   driver_assignments.drivers_can_read_driver_assignments
--                                               -> reads drivers      (cycle)
--   orders.drivers_can_read_orders              -> reads drivers      (cycle)
--   driver_assignments.order_owners_read_assignments
--                                               -> reads orders       (cycle)
--   orders.drivers_can_update_order_status      -> reads driver_assignments
--
-- A policy expression that sub-selects a table whose own policies sub-select
-- back is a cycle, and Postgres refuses to plan it.
--
-- Fix: every cross-table test moves into a SECURITY DEFINER helper. The helpers
-- are owned by postgres, who owns these tables, and none of them has
-- FORCE ROW LEVEL SECURITY, so the lookup inside runs with RLS bypassed and the
-- cycle disappears. This is the same shape as the existing
-- public.is_platform_admin(), which was already SECURITY DEFINER.
--
-- Each helper reads auth.uid() itself and accepts only the row-scoped id, so a
-- caller can never ask about anybody but themselves (passing both ids in from
-- the policy would have let an authenticated client probe the
-- driver<->customer relationship of other accounts).
--
-- Applied to project lxsvydiyzeavdqbjxkpp with MCP apply_migration
-- (fix_recursive_rls_driver_order_policies).
--
-- Verified after applying, using `set local role authenticated` plus a real
-- request.jwt.claims sub:
--   * driver    -> users 41, drivers 1, orders 74, driver_assignments 14,
--                  stores 16, is_driver() true, no error
--   * customer  -> users 1, drivers 1 (only the driver assigned to them),
--                  orders 1, driver_assignments 1
--   * store own -> users 1, stores 16, orders 1, drivers 0, driver_assignments 0
--   * anon      -> every count 0, is_driver() false, no error
--   * select * from public.get_driver_for_order(<order>) returns the assignment
--     plus the driver profile
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. SECURITY DEFINER predicates
-- ---------------------------------------------------------------------------
create or replace function public.is_driver()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.drivers d where d.user_id = auth.uid()
  );
$$;

create or replace function public.is_assigned_driver(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.driver_assignments da
     where da.order_id = p_order_id
       and da.driver_id = auth.uid()
  );
$$;

create or replace function public.order_belongs_to_customer(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.orders o
     where o.id = p_order_id
       and o.user_id = auth.uid()
  );
$$;

create or replace function public.customer_has_driver(p_driver_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.driver_assignments da
      join public.orders o on o.id = da.order_id
     where da.driver_id = p_driver_user_id
       and o.user_id = auth.uid()
  );
$$;

create or replace function public.store_owner_has_driver(p_driver_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.driver_assignments da
      join public.orders o on o.id = da.order_id
      join public.stores s on s.id = o.store_id
     where da.driver_id = p_driver_user_id
       and s.owner_id = auth.uid()
  );
$$;

create or replace function public.store_owner_owns_order(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.orders o
      join public.stores s on s.id = o.store_id
     where o.id = p_order_id
       and s.owner_id = auth.uid()
  );
$$;

comment on function public.is_driver() is
  'True when the caller is a row in public.drivers. SECURITY DEFINER so RLS policies can test it without re-entering drivers.';
comment on function public.is_assigned_driver(uuid) is
  'True when the caller is the assigned driver on the given order. SECURITY DEFINER; replaces the recursive subquery in orders.drivers_can_update_order_status.';
comment on function public.order_belongs_to_customer(uuid) is
  'True when the caller owns the given order. SECURITY DEFINER; replaces the recursive subquery in driver_assignments.order_owners_read_assignments.';
comment on function public.customer_has_driver(uuid) is
  'True when the caller is the customer on a delivery assigned to the given driver. SECURITY DEFINER; replaces drivers.customers_read_assigned_driver.';
comment on function public.store_owner_has_driver(uuid) is
  'True when the caller owns a store on a delivery assigned to the given driver. SECURITY DEFINER; replaces drivers.store_owners_read_assigned_drivers.';
comment on function public.store_owner_owns_order(uuid) is
  'True when the caller owns the store that the given order belongs to. SECURITY DEFINER; replaces the recursive subqueries on orders and driver_assignments.';

-- Supabase grants EXECUTE on new public functions to anon/authenticated by
-- default, so name the roles explicitly rather than relying on `public`.
revoke execute on function public.is_driver() from public;
revoke execute on function public.is_assigned_driver(uuid) from public;
revoke execute on function public.order_belongs_to_customer(uuid) from public;
revoke execute on function public.customer_has_driver(uuid) from public;
revoke execute on function public.store_owner_has_driver(uuid) from public;
revoke execute on function public.store_owner_owns_order(uuid) from public;

grant execute on function public.is_driver() to anon, authenticated, service_role;
grant execute on function public.is_assigned_driver(uuid) to anon, authenticated, service_role;
grant execute on function public.order_belongs_to_customer(uuid) to anon, authenticated, service_role;
grant execute on function public.customer_has_driver(uuid) to anon, authenticated, service_role;
grant execute on function public.store_owner_has_driver(uuid) to anon, authenticated, service_role;
grant execute on function public.store_owner_owns_order(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Rewrite the policies that sub-selected across the cycle
-- ---------------------------------------------------------------------------
-- alter policy (not drop/create) so the command type, the roles the policy
-- applies to and its permissive/restrictive nature are all left untouched.

alter policy "drivers_can_read_customers" on public.users
  using (public.is_driver());

alter policy "customers_read_assigned_driver" on public.drivers
  using (public.customer_has_driver(drivers.user_id));

alter policy "store_owners_read_assigned_drivers" on public.drivers
  using (public.store_owner_has_driver(drivers.user_id));

alter policy "drivers_can_read_orders" on public.orders
  using (public.is_driver());

alter policy "drivers_can_update_order_status" on public.orders
  using (public.is_assigned_driver(orders.id))
  with check (public.is_assigned_driver(orders.id));

alter policy "store_owners_select_orders" on public.orders
  using (public.store_owner_owns_order(orders.id));

alter policy "store_owners_update_orders" on public.orders
  using (public.store_owner_owns_order(orders.id))
  with check (public.store_owner_owns_order(orders.id));

alter policy "drivers_can_read_driver_assignments" on public.driver_assignments
  using (public.is_driver());

alter policy "order_owners_read_assignments" on public.driver_assignments
  using (public.order_belongs_to_customer(driver_assignments.order_id));

alter policy "store_owners_read_store_assignments" on public.driver_assignments
  using (public.store_owner_owns_order(driver_assignments.order_id));

-- NOTE: the users.drivers_can_read_customers set here is replaced by
-- 20261016_000003_tighten_drivers_can_read_customers.sql, which narrows it
-- from "every driver reads every customer" to "a driver reads only the
-- customers they are actually delivering to".
