-- ============================================================================
-- QUELESS — Phase B: automatic dispatch
--
-- Closes the gap left by 20261011_phase_b_dispatch_offers.sql: that migration
-- created the offer machinery (`nearby_eligible_drivers`, `create_dispatch_offer`,
-- `accept_dispatch_offer`, `decline_dispatch_offer`, the timeout sweep) but
-- nothing ever called `create_dispatch_offer`, so no offer could exist.
--
-- Grounded in the LIVE project lxsvydiyzeavdqbjxkpp, read through the Supabase
-- connector on 2026-10-11 (not inferred from model files):
--
--   stores.store_location  geography(Point,4326)   populated on 2 of 16 stores
--   stores.delivery_polygon geometry(Polygon,4326) populated on 0 of 16
--   stores.delivery_radius_km numeric              populated on all 16
--   orders.delivery_address jsonb with latitude + longitude on 73/73 rows
--   0 orders belong to a store that has store_location
--   orders already carries nine triggers, one of them (qai_on_order_status)
--     using the EXCEPTION WHEN OTHERS / RAISE WARNING house style reused below
--   no order is currently open (55 cancelled + 19 delivered = 74), so this is
--     inert until a new order reaches ready_for_pickup
--
-- DISPATCH ORIGIN: store_location when the store has one, otherwise the
-- customer's delivery address. Until stores are geocoded, drivers are therefore
-- ranked by distance to the CUSTOMER rather than to the pickup point. Store
-- coordinates are the real fix; this picks the best available point rather than
-- inventing one.
--
-- PERMITTED AREA: no store has a delivery_polygon, so the postgis polygon could
-- not be used for anything here. The per-store delivery_radius_km is used as the
-- outer cap of the expanding ladder instead.
--
-- Additive and idempotent. Behaviour does not change until an order becomes
-- ready_for_pickup (the trigger) or the tick is scheduled (the retries).
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Where is this order dispatched from?
-- ---------------------------------------------------------------------------

create or replace function public.dispatch_origin(p_order_id uuid)
returns geography
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    s.store_location,
    case
      when nullif(btrim(o.delivery_address ->> 'latitude'), '') is not null
       and nullif(btrim(o.delivery_address ->> 'longitude'), '') is not null
      then st_setsrid(
        st_makepoint(
          (o.delivery_address ->> 'longitude')::double precision,
          (o.delivery_address ->> 'latitude')::double precision
        ),
        4326
      )::geography
    end
  )
  from public.orders o
  left join public.stores s on s.id = o.store_id
  where o.id = p_order_id
$$;

comment on function public.dispatch_origin(uuid) is
  'Dispatch origin for an order: the store location when set, else the customer delivery address point. NULL when neither is available.';


-- ---------------------------------------------------------------------------
-- 2. The expanding radius ladder
--
-- Overridable without a migration:
--   alter database postgres set app.dispatch_radius_ladder_m = '{3000,9000,20000}';
-- ---------------------------------------------------------------------------

create or replace function public.dispatch_radius_ladder_m()
returns double precision[]
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('app.dispatch_radius_ladder_m', true), '')::double precision[],
    '{2000,4000,8000,15000,30000,50000}'::double precision[]
  )
$$;

comment on function public.dispatch_radius_ladder_m() is
  'Expanding dispatch search radii in metres. Overridable via app.dispatch_radius_ladder_m; defaults to 2/4/8/15/30/50 km.';

create or replace function public.dispatch_radius_for_step(
  p_step integer,
  p_max_radius_m double precision default null
)
returns double precision
language sql
stable
as $$
  with ladder as (select public.dispatch_radius_ladder_m() as steps)
  select least(
    ladder.steps[least(greatest(coalesce(p_step, 1), 1), array_length(ladder.steps, 1))],
    greatest(coalesce(p_max_radius_m, 50000), 500)
  )
  from ladder
$$;

comment on function public.dispatch_radius_for_step(integer, double precision) is
  'Ladder entry for a 1-based step, capped by the store delivery radius.';

-- A store cannot deliver beyond its configured radius.
create or replace function public.dispatch_max_radius_m(p_store_id uuid)
returns double precision
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select greatest(coalesce(nullif(s.delivery_radius_km, 0) * 1000, 25000), 1000)
  from public.stores s
  where s.id = p_store_id
$$;

comment on function public.dispatch_max_radius_m(uuid) is
  'Outer cap for dispatch, from stores.delivery_radius_km (default 25 km).';


-- ---------------------------------------------------------------------------
-- 3. Offer this order to the nearest eligible driver
--
-- Reuses create_dispatch_offer rather than inserting by hand, so the offer this
-- creates is identical to one created any other way (one definition of an
-- offer, one place that enforces "no live assignment").
-- ---------------------------------------------------------------------------

create or replace function public.dispatch_next_driver(p_order_id uuid)
returns table (
  assignment_id uuid,
  driver_id uuid,
  attempt integer,
  radius_m double precision
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_store_id uuid;
  v_origin geography;
  v_attempts integer;
  v_escalation integer;
  v_step integer;
  v_radius double precision;
  v_max_radius double precision;
  v_driver uuid;
  v_offer record;
  v_excluded uuid[];
begin
  if p_order_id is null then
    return;
  end if;

  select o.status, o.store_id into v_status, v_store_id
  from public.orders o
  where o.id = p_order_id;

  if not found then
    return;
  end if;

  -- Only orders the store has actually released, and only while nothing is
  -- already live on them.
  if lower(coalesce(v_status, '')) <> 'ready_for_pickup' then
    return;
  end if;

  if exists (
    select 1
    from public.driver_assignments da
    where da.order_id = p_order_id
      and public.driver_assignment_status_is_active(da.status)
  ) then
    return;
  end if;

  v_origin := public.dispatch_origin(p_order_id);

  if v_origin is null then
    raise warning 'dispatch: order % has no usable location (no store coordinate, no delivery address point)', p_order_id;
    return;
  end if;

  select count(*)::integer into v_attempts
  from public.driver_assignments da
  where da.order_id = p_order_id;

  -- Escalate on waiting time as well as on attempts: when a radius finds nobody
  -- at all no row is created, so the attempt count alone would never widen.
  -- greatest() so a stale updated_at cannot push the search straight to the
  -- widest radius; and because candidates are ranked nearest-first, an
  -- over-wide radius can only ever pick the same nearest driver.
  select floor(
           extract(epoch from (now() - greatest(o.updated_at, o.created_at))) / 120
         )::integer
    into v_escalation
  from public.orders o
  where o.id = p_order_id;

  v_max_radius := coalesce(public.dispatch_max_radius_m(v_store_id), 25000);
  v_step := coalesce(v_attempts, 0) + greatest(coalesce(v_escalation, 0), 0) + 1;
  v_radius := public.dispatch_radius_for_step(v_step, v_max_radius);

  -- Everyone who already had a row for this order - accepted, declined or let it
  -- expire - has had their turn.
  select coalesce(array_agg(distinct da.driver_id), array[]::uuid[])
    into v_excluded
  from public.driver_assignments da
  where da.order_id = p_order_id
    and da.driver_id is not null;

  select d.driver_id into v_driver
  from public.nearby_eligible_drivers(
         st_y(v_origin::geometry),
         st_x(v_origin::geometry),
         v_radius,
         1,
         v_excluded
       ) d;

  if v_driver is null then
    return;
  end if;

  select * into v_offer
  from public.create_dispatch_offer(p_order_id, v_driver, null);

  return query
    select v_offer.assignment_id, v_offer.driver_id, v_attempts + 1, v_radius;
end;
$$;

comment on function public.dispatch_next_driver(uuid) is
  'Offers an order to the nearest eligible driver at the current ladder radius; returns nothing when the order is not dispatchable or nobody is eligible.';


-- ---------------------------------------------------------------------------
-- 4. Sweep every waiting order (the retry half of the loop)
-- ---------------------------------------------------------------------------

create or replace function public.auto_dispatch_ready_orders(p_limit integer default 25)
returns table (
  order_id uuid,
  driver_id uuid,
  assignment_id uuid,
  attempt integer,
  radius_m double precision
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  d record;
begin
  for r in
    select o.id
    from public.orders o
    where lower(coalesce(o.status, '')) = 'ready_for_pickup'
      and not exists (
        select 1
        from public.driver_assignments da
        where da.order_id = o.id
          and public.driver_assignment_status_is_active(da.status)
      )
    order by o.created_at
    limit greatest(coalesce(p_limit, 25), 1)
  loop
    begin
      select * into d from public.dispatch_next_driver(r.id);

      if d.driver_id is not null then
        order_id := r.id;
        driver_id := d.driver_id;
        assignment_id := d.assignment_id;
        attempt := d.attempt;
        radius_m := d.radius_m;
        return next;
      end if;
    exception when others then
      -- One bad order must not stop the batch; the next tick retries it.
      raise warning 'auto dispatch failed for order %: %', r.id, sqlerrm;
    end;
  end loop;
end;
$$;

comment on function public.auto_dispatch_ready_orders(integer) is
  'Offers every waiting ready_for_pickup order that has nothing live on it to its nearest eligible driver.';


-- ---------------------------------------------------------------------------
-- 5. One tick: clear what has lapsed, then re-offer what is waiting
--
-- Both halves in a single entry point so a scheduler cannot run them out of
-- order and so the customer never waits a whole extra minute for a retry.
-- ---------------------------------------------------------------------------

create or replace function public.run_dispatch_tick()
returns table (
  offers_stamped integer,
  offers_expired integer,
  orders_requeued integer,
  notifications_sent integer,
  offers_created integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  s record;
  c integer;
begin
  -- Clear lapsed offers first, so an order freed in this tick can be offered
  -- again in the same tick.
  select * into s from public.enforce_dispatch_offer_timeout();

  select count(*)::integer into c from public.auto_dispatch_ready_orders();

  offers_stamped := coalesce(s.offers_stamped, 0);
  offers_expired := coalesce(s.offers_expired, 0);
  orders_requeued := coalesce(s.orders_requeued, 0);
  notifications_sent := coalesce(s.notifications_sent, 0);
  offers_created := c;

  return next;
end;
$$;

comment on function public.run_dispatch_tick() is
  'Single dispatch tick: expire lapsed offers, then offer waiting orders. This is what the cron job calls.';


-- ---------------------------------------------------------------------------
-- 6. Dispatch the moment an order is released
--
-- The tick alone would add up to a minute of dead time between the store
-- accepting an order and a driver hearing about it.
-- ---------------------------------------------------------------------------

create or replace function public.trg_auto_dispatch_on_ready()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d record;
begin
  if lower(coalesce(new.status, '')) = 'ready_for_pickup'
     and lower(coalesce(old.status, '')) is distinct from 'ready_for_pickup'
  then
    begin
      select * into d from public.dispatch_next_driver(new.id);
    exception when others then
      -- Never block the store's own status change: report it and let the
      -- dispatch tick retry on its next run.
      raise warning 'auto dispatch on ready failed for order %: %', new.id, sqlerrm;
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_orders_auto_dispatch on public.orders;
create trigger trg_orders_auto_dispatch
  after update of status on public.orders
  for each row
  execute function public.trg_auto_dispatch_on_ready();


-- ---------------------------------------------------------------------------
-- 7. Permissions
--
-- The definer functions do their own work; none of this may be callable by an
-- app user, because dispatch hands real orders to real drivers.
-- ---------------------------------------------------------------------------

revoke all on function public.dispatch_origin(uuid) from public, anon, authenticated;
grant execute on function public.dispatch_origin(uuid) to service_role;

revoke all on function public.dispatch_radius_ladder_m() from public, anon, authenticated;
grant execute on function public.dispatch_radius_ladder_m() to service_role;

revoke all on function public.dispatch_radius_for_step(integer, double precision) from public, anon, authenticated;
grant execute on function public.dispatch_radius_for_step(integer, double precision) to service_role;

revoke all on function public.dispatch_max_radius_m(uuid) from public, anon, authenticated;
grant execute on function public.dispatch_max_radius_m(uuid) to service_role;

revoke all on function public.dispatch_next_driver(uuid) from public, anon, authenticated;
grant execute on function public.dispatch_next_driver(uuid) to service_role;

revoke all on function public.auto_dispatch_ready_orders(integer) from public, anon, authenticated;
grant execute on function public.auto_dispatch_ready_orders(integer) to service_role;

revoke all on function public.run_dispatch_tick() from public, anon, authenticated;
grant execute on function public.run_dispatch_tick() to service_role;


-- ---------------------------------------------------------------------------
-- Scheduling
--
-- One job, every minute, on the existing pg_cron installation:
--
--   select cron.schedule(
--     'queless-dispatch-tick',
--     '* * * * *',
--     $$select public.run_dispatch_tick()$$
--   );
--
-- Stop it with:  select cron.unschedule('queless-dispatch-tick');
--
-- Rollback:
--   select cron.unschedule('queless-dispatch-tick');
--   drop trigger if exists trg_orders_auto_dispatch on public.orders;
--   drop function if exists public.trg_auto_dispatch_on_ready();
--   drop function if exists public.run_dispatch_tick();
--   drop function if exists public.auto_dispatch_ready_orders(integer);
--   drop function if exists public.dispatch_next_driver(uuid);
--   drop function if exists public.dispatch_max_radius_m(uuid);
--   drop function if exists public.dispatch_radius_for_step(integer, double precision);
--   drop function if exists public.dispatch_radius_ladder_m();
--   drop function if exists public.dispatch_origin(uuid);
-- ---------------------------------------------------------------------------
