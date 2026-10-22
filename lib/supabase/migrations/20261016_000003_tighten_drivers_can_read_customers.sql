-- ============================================================================
-- Tighten users.drivers_can_read_customers to assigned customers only
-- ============================================================================
-- Before this migration, and before the recursion fix in
-- 20261016_000002_fix_recursive_rls_driver_order_policies.sql, the policy was:
--
--   create policy "drivers_can_read_customers" on public.users
--     for select using (
--       exists (select 1 from drivers d where d.user_id = auth.uid())
--     );
--
-- i.e. ANY driver could read EVERY customer row — including `phone` and
-- `email`. That was the policy's original intent, but it never actually leaked
-- anything, because the recursive cycle made every `users` read fail with
-- 42P17. Fixing the recursion silently turned it back on, so it is narrowed
-- here in the same change-set rather than left as a live PII exposure.
--
-- Now a driver may read a customer row only when that customer has an order
-- with an assignment to this driver — which is exactly what the driver app
-- needs (the name and phone for a delivery).
--
-- A driver's own profile is unaffected: users_select_own (auth.uid() = id) is a
-- separate permissive SELECT policy, and permissive policies OR together.
--
-- Applied to project lxsvydiyzeavdqbjxkpp with MCP apply_migration
-- (tighten_drivers_can_read_customers).
--
-- Verified after applying, as the driver 6357e172-… with real assignments:
--   users visible 3 (own row + the 2 customers on their orders),
--   driver_has_customer(self) true, driver_has_customer(<unrelated>) false.
-- ============================================================================

create or replace function public.driver_has_customer(p_customer_id uuid)
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
     where o.user_id = p_customer_id
       and da.driver_id = auth.uid()
  );
$$;

comment on function public.driver_has_customer(uuid) is
  'True when the caller is a driver with an assignment on one of the given customer''s orders. SECURITY DEFINER; keeps users.drivers_can_read_customers free of cross-table RLS re-entry.';

revoke execute on function public.driver_has_customer(uuid) from public;
grant execute on function public.driver_has_customer(uuid) to anon, authenticated, service_role;

alter policy "drivers_can_read_customers" on public.users
  using (public.driver_has_customer(users.id));
