-- ============================================================================
-- QUELESS — Phase B: time-boxed dispatch offers + one active courier per order
--
-- Grounded in the LIVE project lxsvydiyzeavdqbjxkpp, read through the Supabase
-- connector on 2026-10-11 (not inferred from model files):
--
--   public.driver_assignments
--     id, order_id, driver_id, status text NOT NULL DEFAULT 'assigned'
--     (NO check constraint), notes, accepted_at, picked_up_at, delivered_at,
--     cancelled_at, created_at, updated_at, current_lat, current_lng,
--     last_location_update, location_accuracy, location_speed, location_heading
--     UNIQUE (order_id, driver_id, status)
--     FK driver_id -> auth.users(id) and -> drivers(user_id), both ON DELETE SET NULL
--   live status values: 'assigned' x1, 'delivered' x11, 'Picked up' x2
--     -> the column is free-form and already mixed-case, so this migration
--        must not add a status CHECK constraint.
--   orders.delivery_address carries latitude + longitude on 73/73 rows,
--     so dispatch has a delivery origin.
--   public.driver_locations exists (driver_id PK, realtime-enabled) and is
--     EMPTY: nothing publishes driver positions to it yet.
--   drivers.status has no constraint; live values are 'online' 5,
--     'offline' 5, 'deleted' 7, with 4 rows passing online+not-soft-deleted.
--   pg_cron 1.6.4, pg_net 0.19.5, supabase_vault and postgis are installed;
--     five existing qai_* cron jobs call SQL functions directly. This
--     migration therefore exposes the sweep as a SQL function so it can be
--     scheduled the same way (see the note at the bottom before scheduling).
--   No order currently has two active assignments, so the unique index below
--     can be created without a conflict.
--
-- Additive and idempotent. Behaviour does not change until a caller creates an
-- offer and the sweep is scheduled.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Offer columns on driver_assignments
-- ---------------------------------------------------------------------------

alter table public.driver_assignments
  add column if not exists offer_expires_at timestamptz,
  add column if not exists timeout_seconds integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.driver_assignments'::regclass
      and conname = 'driver_assignments_timeout_seconds_positive'
  ) then
    alter table public.driver_assignments
      add constraint driver_assignments_timeout_seconds_positive
      check (timeout_seconds is null or timeout_seconds > 0);
  end if;
end
$$;

comment on column public.driver_assignments.offer_expires_at is
  'Absolute expiry of a pending dispatch offer (created_at + timeout_seconds). NULL when the row is not a live offer.';

comment on column public.driver_assignments.timeout_seconds is
  'Dispatch offer timeout in seconds that produced offer_expires_at. NULL when the row is not a live offer.';


-- ---------------------------------------------------------------------------
-- 2. Status vocabulary: which assignment statuses are still "live"
--
-- Terminal (frees the order for another driver): delivered, cancelled/ canceled,
-- expired, declined, failed, rejected. Everything else - including the legacy
-- 'assigned' and the mixed-case 'Picked up' already in the table - is active.
-- ---------------------------------------------------------------------------

create or replace function public.driver_assignment_status_is_active(p_status text)
returns boolean
language sql
immutable
as $$
  select lower(coalesce(p_status, '')) not in (
    'delivered', 'cancelled', 'canceled', 'expired',
    'declined', 'failed', 'failed_delivery', 'rejected'
  )
$$;


-- ---------------------------------------------------------------------------
-- 3. At most one live assignment per order  ("only one driver can win")
--
-- Today the driver app checks for an existing assignment and then inserts one
-- (queless_driver/lib/services/order_service.dart). Two drivers doing that at
-- the same time both succeed, because the only uniqueness is
-- (order_id, driver_id, status). This partial index makes the race safe: the
-- loser gets a unique_violation instead of a silent second courier.
-- ---------------------------------------------------------------------------

create unique index if not exists driver_assignments_one_active_per_order_idx
  on public.driver_assignments (order_id)
  where lower(coalesce(status, '')) not in (
    'delivered', 'cancelled', 'canceled', 'expired',
    'declined', 'failed', 'failed_delivery', 'rejected'
  );

comment on index public.driver_assignments_one_active_per_order_idx is
  'Guarantees a single live courier per order; terminal rows keep the audit history.';


-- ---------------------------------------------------------------------------
-- 4. Index for the expiry sweep + realtime so offers reach drivers live
-- ---------------------------------------------------------------------------

create index if not exists driver_assignments_live_offer_expiry_idx
  on public.driver_assignments (offer_expires_at)
  where offer_expires_at is not null;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'driver_assignments'
  ) then
    alter publication supabase_realtime add table public.driver_assignments;
  end if;
end
$$;


-- ---------------------------------------------------------------------------
-- 5. Configurable timeout, env-style, with a hardcoded default
--
-- Read with current_setting so it can be changed per-database without a
-- migration:  alter database postgres set app.dispatch_offer_timeout_seconds = '90';
-- ---------------------------------------------------------------------------

create or replace function public.dispatch_offer_timeout_seconds()
returns integer
language sql
stable
as $$
  select greatest(
    coalesce(
      nullif(current_setting('app.dispatch_offer_timeout_seconds', true), '')::integer,
      60
    ),
    1
  )
$$;

comment on function public.dispatch_offer_timeout_seconds() is
  'Dispatch offer timeout in seconds. Overridable via app.dispatch_offer_timeout_seconds; defaults to 60.';


-- ---------------------------------------------------------------------------
-- 6. Nearest eligible drivers
--
-- Eligibility, from the live data: a real driver, online, not soft-deleted,
-- with a position seen in the last 15 minutes, and not already carrying a live
-- assignment. Drivers with no fresh position are excluded by design - the
-- driver app must publish to driver_locations for anyone to be dispatchable.
-- ---------------------------------------------------------------------------

create or replace function public.nearby_eligible_drivers(
  p_lat double precision,
  p_lng double precision,
  p_radius_m double precision default 5000,
  p_limit integer default 10,
  p_exclude_driver_ids uuid[] default null
)
returns table (
  driver_id uuid,
  distance_m double precision,
  full_name text,
  vehicle_type text,
  rating numeric,
  location_age interval
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    d.user_id,
    st_distance(
      st_setsrid(st_makepoint(dl.current_lng, dl.current_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography
    ) as distance_m,
    d.full_name,
    d.vehicle_type,
    d.rating,
    now() - dl.last_location_update as location_age
  from public.drivers d
  join public.driver_locations dl on dl.driver_id = d.user_id
  where lower(coalesce(d.status, '')) = 'online'
    and d.deleted_at is null
    and coalesce(d.role_type, 'driver') = 'driver'
    and dl.current_lat is not null
    and dl.current_lng is not null
    and dl.last_location_update > now() - interval '15 minutes'
    and (p_exclude_driver_ids is null or not (d.user_id = any (p_exclude_driver_ids)))
    and not exists (
      select 1
      from public.driver_assignments da
      where da.driver_id = d.user_id
        and public.driver_assignment_status_is_active(da.status)
    )
    and st_distance(
      st_setsrid(st_makepoint(dl.current_lng, dl.current_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography
    ) <= p_radius_m
  order by 2
  limit greatest(coalesce(p_limit, 10), 1)
$$;


-- ---------------------------------------------------------------------------
-- 7. Create an offer (used by the store/admin action and by auto-dispatch)
-- ---------------------------------------------------------------------------

create or replace function public.create_dispatch_offer(
  p_order_id uuid,
  p_driver_id uuid,
  p_timeout_seconds integer default null
)
returns table (
  assignment_id uuid,
  order_id uuid,
  driver_id uuid,
  offer_expires_at timestamptz,
  timeout_seconds integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeout integer := coalesce(p_timeout_seconds, public.dispatch_offer_timeout_seconds());
  v_expires timestamptz;
  v_id uuid;
  v_order_status text;
  v_store_id uuid;
begin
  if p_order_id is null or p_driver_id is null then
    raise exception 'create_dispatch_offer: order and driver are required'
      using errcode = '22023';
  end if;

  if v_timeout <= 0 then
    raise exception 'create_dispatch_offer: timeout must be positive'
      using errcode = '22023';
  end if;

  select o.status, o.store_id into v_order_status, v_store_id
  from public.orders o
  where o.id = p_order_id
  for update;

  if not found then
    raise exception 'create_dispatch_offer: order % does not exist', p_order_id
      using errcode = '23503';
  end if;

  -- A signed-in caller must be a platform admin or the owning store owner.
  -- A null auth.uid() means a trusted server-side call (service role).
  if auth.uid() is not null then
    if not (
      public.is_platform_admin(auth.uid())
      or exists (
        select 1 from public.stores s
        where s.id = v_store_id and s.owner_id = auth.uid()
      )
    ) then
      raise exception 'create_dispatch_offer: not authorized for order %', p_order_id
        using errcode = '42501';
    end if;
  end if;

  if lower(coalesce(v_order_status, '')) in
     ('delivered', 'cancelled', 'canceled', 'refunded', 'rejected') then
    raise exception 'create_dispatch_offer: order % is already closed (%)',
      p_order_id, v_order_status
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.driver_assignments da
    where da.order_id = p_order_id
      and public.driver_assignment_status_is_active(da.status)
  ) then
    raise exception 'create_dispatch_offer: order % already has a live assignment', p_order_id
      using errcode = '23505';
  end if;

  v_expires := now() + make_interval(secs => v_timeout);

  insert into public.driver_assignments (
    order_id, driver_id, status, offer_expires_at, timeout_seconds
  )
  values (p_order_id, p_driver_id, 'offered', v_expires, v_timeout)
  returning id into v_id;

  return query select v_id, p_order_id, p_driver_id, v_expires, v_timeout;
end;
$$;


-- ---------------------------------------------------------------------------
-- 8. Driver accepts / declines an offer
-- ---------------------------------------------------------------------------

create or replace function public.accept_dispatch_offer(p_assignment_id uuid)
returns table (
  assignment_id uuid,
  order_id uuid,
  order_status text,
  accepted_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_driver uuid := auth.uid();
  v_row public.driver_assignments%rowtype;
  v_now timestamptz := now();
  v_tracking jsonb;
  v_status text;
begin
  if v_driver is null then
    raise exception 'accept_dispatch_offer: not authenticated'
      using errcode = '28000';
  end if;

  -- Row lock: a concurrent accept/decline/expiry for this offer serialises here.
  select * into v_row
  from public.driver_assignments
  where id = p_assignment_id
  for update;

  if not found then
    raise exception 'accept_dispatch_offer: offer % does not exist', p_assignment_id
      using errcode = '23503';
  end if;

  if v_row.driver_id is distinct from v_driver then
    raise exception 'accept_dispatch_offer: offer % is not addressed to you', p_assignment_id
      using errcode = '42501';
  end if;

  if lower(coalesce(v_row.status, '')) <> 'offered' then
    raise exception 'accept_dispatch_offer: offer is no longer open (status %)', v_row.status
      using errcode = '22023';
  end if;

  if v_row.offer_expires_at is not null and v_row.offer_expires_at <= v_now then
    raise exception 'accept_dispatch_offer: offer expired at %', v_row.offer_expires_at
      using errcode = '22023';
  end if;

  -- Respect the order state machine: a driver may only take an order the store
  -- has actually released for pickup (ready_for_pickup) or that is already his.
  -- Without this, accepting an offer on a still-'preparing' order would push it
  -- straight to 'driver_assigned' and skip the store's handover step.
  select o.status into v_status
  from public.orders o
  where o.id = v_row.order_id
  for update;

  if not found then
    raise exception 'accept_dispatch_offer: order % does not exist', v_row.order_id
      using errcode = '23503';
  end if;

  if lower(coalesce(v_status, '')) not in ('ready_for_pickup', 'driver_assigned') then
    raise exception 'accept_dispatch_offer: order % is not awaiting a driver (status %)',
      v_row.order_id, v_status
      using errcode = '22023';
  end if;

  update public.driver_assignments
     set status = 'assigned',
         accepted_at = v_now,
         offer_expires_at = null,
         timeout_seconds = null,
         updated_at = v_now
   where id = p_assignment_id;

  -- Customer timeline: same shape and de-dupe rule as the orders-status
  -- function - {status, message, timestamp}, never twice in a row.
  select o.tracking_updates into v_tracking
  from public.orders o
  where o.id = v_row.order_id;

  if v_tracking is null or jsonb_typeof(v_tracking) <> 'array' then
    v_tracking := '[]'::jsonb;
  end if;

  if v_tracking -> -1 ->> 'status' is distinct from 'driver_assigned' then
    v_tracking := v_tracking || jsonb_build_object(
      'status', 'driver_assigned',
      'message', 'Driver assigned and heading to store',
      'timestamp', to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    );
  end if;

  update public.orders
     set status = 'driver_assigned',
         tracking_updates = v_tracking,
         updated_at = v_now
   where id = v_row.order_id
  returning status into v_status;

  return query select p_assignment_id, v_row.order_id, v_status, v_now;
end;
$$;


create or replace function public.decline_dispatch_offer(
  p_assignment_id uuid,
  p_reason text default null
)
returns table (
  assignment_id uuid,
  order_id uuid,
  declined_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_driver uuid := auth.uid();
  v_row public.driver_assignments%rowtype;
  v_now timestamptz := now();
begin
  if v_driver is null then
    raise exception 'decline_dispatch_offer: not authenticated'
      using errcode = '28000';
  end if;

  select * into v_row
  from public.driver_assignments
  where id = p_assignment_id
  for update;

  if not found then
    raise exception 'decline_dispatch_offer: offer % does not exist', p_assignment_id
      using errcode = '23503';
  end if;

  if v_row.driver_id is distinct from v_driver then
    raise exception 'decline_dispatch_offer: offer % is not addressed to you', p_assignment_id
      using errcode = '42501';
  end if;

  if lower(coalesce(v_row.status, '')) <> 'offered' then
    raise exception 'decline_dispatch_offer: offer is no longer open (status %)', v_row.status
      using errcode = '22023';
  end if;

  update public.driver_assignments
     set status = 'declined',
         notes = nullif(
           concat_ws(' | ', nullif(v_row.notes, ''), nullif(btrim(coalesce(p_reason, '')), '')),
           ''
         ),
         offer_expires_at = null,
         timeout_seconds = null,
         updated_at = v_now
   where id = p_assignment_id;

  -- 'declined' is terminal, so the partial unique index frees the order for the
  -- next driver without touching anything else.
  return query select p_assignment_id, v_row.order_id, v_now;
end;
$$;


-- ---------------------------------------------------------------------------
-- 9. The sweep (schedule this with pg_cron, like the existing qai_* jobs)
--
-- Two passes, both idempotent:
--   stamp  - live offers with no expiry get created_at + configured timeout
--   expire - lapsed offers are cleared, the order is requeued and the customer
--            gets one timeline entry plus one inbox notification
-- ---------------------------------------------------------------------------

create or replace function public.enforce_dispatch_offer_timeout()
returns table (
  offers_stamped integer,
  offers_expired integer,
  orders_requeued integer,
  notifications_sent integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeout integer := public.dispatch_offer_timeout_seconds();
  v_now timestamptz := now();
  v_stamped integer := 0;
  v_expired integer := 0;
  v_requeued integer := 0;
  v_notified integer := 0;
  v_tracking jsonb;
  v_order_status text;
  r record;
begin
  -- Pass 1 - stamp offers that were created without an expiry.
  update public.driver_assignments da
     set offer_expires_at = da.created_at + make_interval(secs => v_timeout),
         timeout_seconds = v_timeout,
         updated_at = v_now
   where lower(coalesce(da.status, '')) = 'offered'
     and da.offer_expires_at is null;

  get diagnostics v_stamped = row_count;

  -- Pass 2 - clear everything past its expiry.
  for r in
    update public.driver_assignments da
       set status = 'expired',
           offer_expires_at = null,
           timeout_seconds = null,
           updated_at = v_now
     where lower(coalesce(da.status, '')) = 'offered'
       and da.offer_expires_at is not null
       and da.offer_expires_at <= v_now
    returning da.id, da.order_id, da.driver_id
  loop
    v_expired := v_expired + 1;

    -- Only requeue when nothing live is left on the order.
    if exists (
      select 1 from public.driver_assignments x
      where x.order_id = r.order_id
        and public.driver_assignment_status_is_active(x.status)
    ) then
      continue;
    end if;

    select o.status, coalesce(o.tracking_updates, '[]'::jsonb)
      into v_order_status, v_tracking
    from public.orders o
    where o.id = r.order_id;

    if not found then
      continue;
    end if;

    if jsonb_typeof(v_tracking) <> 'array' then
      v_tracking := '[]'::jsonb;
    end if;

    if v_tracking -> -1 ->> 'status' is distinct from 'ready_for_pickup' then
      v_tracking := v_tracking || jsonb_build_object(
        'status', 'ready_for_pickup',
        'message', 'The driver did not respond in time, so your order is back in the queue and we are assigning another driver.',
        'timestamp', to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      );
    end if;

    update public.orders o
       set status = case
             when lower(coalesce(o.status, '')) = 'driver_assigned' then 'ready_for_pickup'
             else o.status
           end,
           tracking_updates = v_tracking,
           updated_at = v_now
     where o.id = r.order_id;

    v_requeued := v_requeued + 1;

    -- One inbox row per order: the table has
    -- UNIQUE (order_id, user_id, type) WHERE order_id IS NOT NULL.
    insert into public.notifications (
      user_id, type, title, body, order_id, order_number, status, data
    )
    select
      o.user_id,
      'order',
      'Finding you another driver',
      'The driver did not respond in time. Your order is back in the queue and another driver is being assigned.',
      o.id,
      o.order_number,
      'ready_for_pickup',
      jsonb_build_object(
        'order_id', o.id,
        'order_number', coalesce(o.order_number, ''),
        'status', 'ready_for_pickup',
        'source', 'enforce_dispatch_offer_timeout',
        'event', 'dispatch_offer_expired',
        'driver_id', r.driver_id
      )
    from public.orders o
    where o.id = r.order_id
      and o.user_id is not null
    on conflict (order_id, user_id, type) where order_id is not null
    do update
       set body = excluded.body,
           status = excluded.status,
           data = excluded.data,
           is_read = false,
           created_at = v_now,
           updated_at = v_now;

    v_notified := v_notified + 1;
  end loop;

  return query select v_stamped, v_expired, v_requeued, v_notified;
end;
$$;


-- ---------------------------------------------------------------------------
-- 10. Permissions
--
-- New functions are EXECUTE-able by PUBLIC by default, so revoke first. The
-- definer functions do their own authorisation internally.
-- ---------------------------------------------------------------------------

revoke all on function public.driver_assignment_status_is_active(text) from public, anon, authenticated;
grant execute on function public.driver_assignment_status_is_active(text) to service_role;

revoke all on function public.dispatch_offer_timeout_seconds() from public, anon;
grant execute on function public.dispatch_offer_timeout_seconds() to authenticated, service_role;

revoke all on function public.nearby_eligible_drivers(double precision, double precision, double precision, integer, uuid[]) from public, anon;
grant execute on function public.nearby_eligible_drivers(double precision, double precision, double precision, integer, uuid[]) to authenticated, service_role;

revoke all on function public.create_dispatch_offer(uuid, uuid, integer) from public, anon;
grant execute on function public.create_dispatch_offer(uuid, uuid, integer) to authenticated, service_role;

revoke all on function public.accept_dispatch_offer(uuid) from public, anon;
grant execute on function public.accept_dispatch_offer(uuid) to authenticated, service_role;

revoke all on function public.decline_dispatch_offer(uuid, text) from public, anon;
grant execute on function public.decline_dispatch_offer(uuid, text) to authenticated, service_role;

-- The sweep is scheduler-only.
revoke all on function public.enforce_dispatch_offer_timeout() from public, anon, authenticated;
grant execute on function public.enforce_dispatch_offer_timeout() to service_role;


-- ---------------------------------------------------------------------------
-- Scheduling note (scheduled as part of the dispatch tick, not here)
--
-- This migration deliberately does not schedule anything: DDL and behaviour
-- stay separate. The sweep is now driven by the combined tick created in
-- 20261011_phase_b_auto_dispatch.sql, which expires lapsed offers first and
-- then re-offers whatever is waiting:
--
--   select cron.schedule(
--     'queless-dispatch-tick',
--     '* * * * *',                       -- pg_cron's finest granularity
--     $$select public.run_dispatch_tick()$$
--   );
--
-- Stop the whole loop (reversible) with:
--   select cron.unschedule('queless-dispatch-tick');
--
-- A 60 second timeout with a 60 second sweep cadence can leave an offer live
-- for up to ~120 seconds before it is cleared.
--
-- Rollback:
--   select cron.unschedule('queless-dispatch-tick');
--   drop function if exists public.enforce_dispatch_offer_timeout();
--   drop function if exists public.decline_dispatch_offer(uuid, text);
--   drop function if exists public.accept_dispatch_offer(uuid);
--   drop function if exists public.create_dispatch_offer(uuid, uuid, integer);
--   drop function if exists public.nearby_eligible_drivers(double precision, double precision, double precision, integer, uuid[]);
--   drop function if exists public.dispatch_offer_timeout_seconds();
--   drop function if exists public.driver_assignment_status_is_active(text);
--   drop index if exists public.driver_assignments_one_active_per_order_idx;
--   drop index if exists public.driver_assignments_live_offer_expiry_idx;
--   alter publication supabase_realtime drop table public.driver_assignments;
--   alter table public.driver_assignments
--     drop constraint if exists driver_assignments_timeout_seconds_positive,
--     drop column if exists timeout_seconds,
--     drop column if exists offer_expires_at;
-- ---------------------------------------------------------------------------
