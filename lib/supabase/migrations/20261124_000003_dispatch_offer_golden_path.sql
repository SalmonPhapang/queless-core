-- ============================================================================
-- Corrective migration: dispatch offer golden-path gaps
--
--   1. Offer timeout default 60s -> 30s (still overridable with
--      app.dispatch_offer_timeout_seconds).
--   2. A notification row is written when an offer is created (driver inbox)
--      and when accept_dispatch_offer succeeds (customer inbox). The existing
--      AFTER INSERT trigger on notifications forwards both to dispatchnotify
--      via pg_net; that function pushes driver-<id> (FCM-only) and
--      order-<number> (FCM + Expo/Web) respectively.
--   3. Declining an offer immediately calls dispatch_next_driver instead of
--      waiting for the next minute tick.
--
-- Remaining limitation (unchanged by design): EXPIRY still relies on the
-- pg_cron minute tick ('queless-dispatch-tick'), which is pg_cron's finest
-- granularity. The 30-second deadline itself is enforced exactly at accept
-- time in accept_dispatch_offer(); the sweep only clears/re-offers lapsed rows,
-- so a customer's "finding you another driver" push can arrive up to ~90s after
-- the offer was created (30s deadline + up to 60s until the next tick). No new
-- cron job or scheduling is added here.
--
-- As in 20261124_000002, the pg_net URL/anon key are inherited from the
-- already-applied queue_dispatch_notification() definition, not re-hardcoded.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. 30-second default
-- ---------------------------------------------------------------------------
create or replace function public.dispatch_offer_timeout_seconds()
returns integer
language sql
stable
as $$
  select greatest(
    coalesce(
      nullif(current_setting('app.dispatch_offer_timeout_seconds', true), '')::integer,
      30
    ),
    1
  )
$$;

comment on function public.dispatch_offer_timeout_seconds() is
  'Dispatch offer timeout in seconds. Overridable via app.dispatch_offer_timeout_seconds; defaults to 30.';


-- The two new inbox writes below use a distinct notification type plus an
-- explicit `not exists` guard instead of ON CONFLICT. The ledger and the live
-- database disagree about whether the (order_id, user_id, type) index is full
-- or partial, so this avoids coupling the golden path to that detail.


-- ---------------------------------------------------------------------------
-- 2. Forward the two new server-originated events to dispatchnotify.
--    Only the whitelist changes; the wrapper still passes the notification
--    row id and lets the edge function build the message.
-- ---------------------------------------------------------------------------
do $$
declare
    v_src text;
    v_url text;
    v_key text;
begin
    select p.prosrc
      into v_src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'queue_dispatch_notification';

    v_url := substring(v_src from '_edge_url[[:space:]]*:=[[:space:]]*''([^'']+)''');
    v_key := substring(v_src from '_anon_key[[:space:]]*:=[[:space:]]*''([^'']+)''');

    if v_url is null or v_key is null then
        raise exception
            'queue_dispatch_notification: could not inherit the existing edge URL/key; '
            'set app.queless_functions_url and app.queless_supabase_anon_key first';
    end if;

    execute format($fn$
    create or replace function public.queue_dispatch_notification()
    returns trigger
    language plpgsql
    security definer
    set search_path = public, extensions, pg_catalog
    as $body$
    declare
        _edge_url text := %L;
        _anon_key text := %L;
        _body jsonb;
        _event text;
        _type text;
        _source text;
    begin
        _edge_url := coalesce(
            nullif(current_setting('app.queless_functions_url', true), ''), _edge_url
        );
        _anon_key := coalesce(
            nullif(current_setting('app.queless_supabase_anon_key', true), ''), _anon_key
        );

        _type := lower(coalesce(NEW.type, ''));
        _event := lower(coalesce((NEW.data ->> 'event')::text, ''));
        _source := lower(coalesce((NEW.data ->> 'source')::text, ''));

        -- Driver offer push, customer expiry push and customer accept push.
        -- The source check stops a client-inserted inbox row (RLS permits
        -- users to insert their own notifications) from forcing a push.
        if _type not in ('order', 'dispatch_offer', 'driver_assigned') then
            return NEW;
        end if;
        if _event not in (
            'dispatch_offer_expired',
            'dispatch_offer_created',
            'dispatch_offer_accepted'
        ) then
            return NEW;
        end if;
        if _source not in (
            'enforce_dispatch_offer_timeout',
            'create_dispatch_offer',
            'accept_dispatch_offer'
        ) then
            return NEW;
        end if;

        _body := jsonb_build_object('id', NEW.id::text);

        perform extensions.net.http_post(
            url     := _edge_url,
            body    := _body::text,
            headers := format(
                '{"Content-Type":"application/json","Authorization":"Bearer %%s"}',
                _anon_key
            )::jsonb
        );

        return NEW;
    end;
    $body$;
    $fn$, v_url, v_key);
end
$$;

revoke all on function public.queue_dispatch_notification() from public;
grant execute on function public.queue_dispatch_notification()
    to postgres, anon, authenticated, service_role;

-- The AFTER INSERT trigger notifications_after_insert_dispatch_push from
-- 20261011_add_dispatch_notification_push.sql is unchanged.


-- ---------------------------------------------------------------------------
-- 3. create_dispatch_offer: also write the driver's durable inbox row, which
--    fires the push trigger above. Notification failure never blocks an offer.
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
  v_order_number text;
begin
  if p_order_id is null or p_driver_id is null then
    raise exception 'create_dispatch_offer: order and driver are required'
      using errcode = '22023';
  end if;

  if v_timeout <= 0 then
    raise exception 'create_dispatch_offer: timeout must be positive'
      using errcode = '22023';
  end if;

  select o.status, o.store_id, o.order_number
    into v_order_status, v_store_id, v_order_number
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

  -- The inbox row is durable (offline drivers still see the offer later) and
  -- its INSERT fires queue_dispatch_notification -> dispatchnotify, which
  -- sends an FCM-only push to driver-<driver_id>.
  begin
    -- Own type + explicit guard: no dependency on the (order_id, user_id, type)
    -- index whose exact shape differs between the ledger and the live project.
    if not exists (
      select 1 from public.notifications n
       where n.order_id = p_order_id::text
         and n.user_id = p_driver_id
         and n.type = 'dispatch_offer'
         and n.data ->> 'event' = 'dispatch_offer_created'
    ) then
      insert into public.notifications (
        user_id, type, title, body, order_id, order_number, status, data
      )
      select
        p_driver_id,
        'dispatch_offer',
        'New delivery offer',
        format('An order near you is ready for pickup. Respond within %s seconds.', v_timeout),
        p_order_id::text,
        coalesce(v_order_number, ''),
        'ready_for_pickup',
        jsonb_build_object(
          'order_id', p_order_id::text,
          'order_number', coalesce(v_order_number, ''),
          'driver_id', p_driver_id::text,
          'assignment_id', v_id::text,
          'store_id', coalesce(v_store_id::text, ''),
          'topic', 'driver-' || p_driver_id::text,
          'offer_expires_at', to_char(v_expires at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'event', 'dispatch_offer_created',
          'source', 'create_dispatch_offer'
        );
    end if;
  exception when others then
    -- A notification problem must never undo a valid offer.
    raise warning 'create_dispatch_offer: offer notification failed for order %: %',
      p_order_id, sqlerrm;
  end;

  return query select v_id, p_order_id, p_driver_id, v_expires, v_timeout;
end;
$$;


-- ---------------------------------------------------------------------------
-- 4. accept_dispatch_offer: notify the customer once the RPC has committed
--    the assignment and moved the order to driver_assigned.
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
  v_user_id uuid;
  v_order_number text;
  v_store_id uuid;
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
  select o.status, o.user_id, o.order_number, o.store_id
    into v_status, v_user_id, v_order_number, v_store_id
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

  -- Customer inbox + push: the RPC (not orders-status) owns this transition,
  -- so without this row the customer learns about the driver only on next
  -- open. queue_dispatch_notification forwards it to dispatchnotify, which
  -- uses order-<order_number> and the shared Expo/Web Push mirror.
  if v_user_id is not null then
    begin
      -- Dedicated type avoids colliding with the single 'order' inbox row that
      -- orders-status/new-order-notify already own for this order.
      if not exists (
        select 1 from public.notifications n
         where n.order_id = v_row.order_id::text
           and n.user_id = v_user_id
           and n.type = 'driver_assigned'
           and n.data ->> 'event' = 'dispatch_offer_accepted'
      ) then
        insert into public.notifications (
          user_id, type, title, body, order_id, order_number, status, data
        )
        values (
          v_user_id,
          'driver_assigned',
          'Driver assigned',
          'A driver has accepted your delivery and is heading to the store.',
          v_row.order_id::text,
          coalesce(v_order_number, ''),
          'driver_assigned',
          jsonb_build_object(
            'order_id', v_row.order_id::text,
            'order_number', coalesce(v_order_number, ''),
            'driver_id', v_driver::text,
            'assignment_id', p_assignment_id::text,
            'store_id', coalesce(v_store_id::text, ''),
            'status', 'driver_assigned',
            'event', 'dispatch_offer_accepted',
            'source', 'accept_dispatch_offer'
          )
        );
      end if;
    exception when others then
      raise warning 'accept_dispatch_offer: customer notification failed for order %: %',
        v_row.order_id, sqlerrm;
    end;
  end if;

  return query select p_assignment_id, v_row.order_id, v_status, v_now;
end;
$$;


-- ---------------------------------------------------------------------------
-- 5. decline_dispatch_offer: retry immediately. 'declined' is terminal, so
--    the partial unique index frees the order before dispatch_next_driver
--    checks for a live assignment. Failures never fail the decline itself;
--    the minute tick remains the backstop.
-- ---------------------------------------------------------------------------
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
  v_jwt_sub text := current_setting('request.jwt.claim.sub', true);
  v_jwt_claims text := current_setting('request.jwt.claims', true);
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

  -- create_dispatch_offer treats a NULL auth.uid() as a trusted server-side
  -- call. Temporarily clear the request's JWT claims so the declining driver's
  -- session can re-offer the order, then restore them before returning. The
  -- exception handler is nested so restoration always happens.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  begin
    perform 1 from public.dispatch_next_driver(v_row.order_id);
  exception when others then
    raise warning 'decline_dispatch_offer: immediate re-dispatch failed for order %: %',
      v_row.order_id, sqlerrm;
  end;
  perform set_config('request.jwt.claim.sub', coalesce(v_jwt_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(v_jwt_claims, ''), true);

  return query select p_assignment_id, v_row.order_id, v_now;
end;
$$;


-- ---------------------------------------------------------------------------
-- 6. Permissions (unchanged from the original phase-B migrations; repeated so
--    a fresh or partially-applied database ends up in the same state).
-- ---------------------------------------------------------------------------
revoke all on function public.dispatch_offer_timeout_seconds() from public, anon;
grant execute on function public.dispatch_offer_timeout_seconds() to authenticated, service_role;

revoke all on function public.create_dispatch_offer(uuid, uuid, integer) from public, anon;
grant execute on function public.create_dispatch_offer(uuid, uuid, integer) to authenticated, service_role;

revoke all on function public.accept_dispatch_offer(uuid) from public, anon;
grant execute on function public.accept_dispatch_offer(uuid) to authenticated, service_role;

revoke all on function public.decline_dispatch_offer(uuid, text) from public, anon;
grant execute on function public.decline_dispatch_offer(uuid, text) to authenticated, service_role;
