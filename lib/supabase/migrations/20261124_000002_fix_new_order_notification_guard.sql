-- ============================================================================
-- Corrective migration: stop queue_new_order_notification() from flipping the
-- new-order notification guard before the edge function has confirmed payment.
--
-- The historical 20260908_notifications_trigger_guards.sql function performed
-- the conditional UPDATE `notifications_attempted = false -> true` itself and
-- then queued new-order-notify. The edge function saw the guard already true
-- and returned `{ skipped: true }`, so no order was ever notified by that
-- path. orders-create compounded it by calling the function for a still
-- unpaid (payment_status='pending') order, consuming the single attempt
-- before the Paystack webhook arrived.
--
-- THE RULE NOW: the SQL trigger only queues HTTP calls; the EDGE FUNCTION owns
-- the guard and flips it only after it has confirmed the order is paid. COD-
-- style methods are paid immediately (no webhook) and keep working.
--
-- The endpoint/anon key are deliberately NOT re-hardcoded here. They are read
-- out of the already-applied function definition at migration time, so the
-- values remain exactly the environment-specific ones installed by the
-- historical migration. Set app.queless_functions_url /
-- app.queless_supabase_anon_key on the database to override them later.
-- ============================================================================

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
       and p.proname = 'queue_new_order_notification';

    v_url := substring(v_src from '_edge_url[[:space:]]*:=[[:space:]]*''([^'']+)''');
    v_key := substring(v_src from '_anon_key[[:space:]]*:=[[:space:]]*''([^'']+)''');

    if v_url is null or v_key is null then
        raise exception
            'queue_new_order_notification: could not inherit the existing edge URL/key; '
            'set app.queless_functions_url and app.queless_supabase_anon_key first';
    end if;

    execute format($fn$
    create or replace function public.queue_new_order_notification()
    returns trigger
    language plpgsql
    security definer
    set search_path = public, extensions, pg_catalog
    as $body$
    declare
        _is_paid boolean;
        -- Inherited from the applied migration; the format() interpolation
        -- keeps the `_edge_url := '...'` shape so this migration is re-runnable.
        _edge_url text := %L;
        _anon_key text := %L;
        _body jsonb;
    begin
        _edge_url := coalesce(
            nullif(current_setting('app.queless_functions_url', true), ''), _edge_url
        );
        _anon_key := coalesce(
            nullif(current_setting('app.queless_supabase_anon_key', true), ''), _anon_key
        );

        -- Already notified (guard now flipped by the edge function only).
        if NEW.notifications_attempted then
            return NEW;
        end if;

        -- Only fire for orders the notifier will actually accept: a completed
        -- payment or an offline/COD method that never waits for a webhook.
        _is_paid := (
            lower(coalesce(NEW.payment_status, '')) = 'completed'
            or lower(trim(coalesce(NEW.payment_method, ''))) in (
                'cash','cod','cash_on_delivery','card_on_delivery',
                'speed_point','speedpoint','eft','in_store'
            )
        );

        if not _is_paid or NEW.store_id is null then
            return NEW;
        end if;

        -- NO conditional UPDATE here. new-order-notify checks payment first,
        -- then flips the guard exactly once on successful dispatch. Duplicate
        -- pg_net calls are safe: the losing invocation is skipped by the edge
        -- function's conditional UPDATE.
        _body := jsonb_build_object(
            'order_id', NEW.id::text,
            'store_id', NEW.store_id::text
        );

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

revoke all on function public.queue_new_order_notification() from public;
grant execute on function public.queue_new_order_notification()
    to postgres, anon, authenticated, service_role;

-- The AFTER INSERT / AFTER UPDATE triggers from the historical migration are
-- unchanged and continue to call this function by OID.
