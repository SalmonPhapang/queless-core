-- =====================================================================
-- Migration: 20260908_notifications_trigger_guards
-- Purpose:   Guarantee delivery of new-order notifications even when the
--            client-side invocation of `new-order-notify` edge function
--            is skipped (offline payment, network failure, Paystack
--            webhook-only flow, mid-request crash).
--
-- Strategy:
--   1. Add a boolean guard column `orders.notifications_attempted`
--      (DEFAULT false) used as an atomic idempotency flag so that the
--      database trigger AND the client-side call never both fire the
--      edge function -- the first to perform a conditional UPDATE
--      `... WHERE notifications_attempted = false` wins.
--   2. `pg_net.http_post` fires the edge function ASYNCHRONOUSLY from
--      inside Postgres so the trigger never blocks the user's INSERT.
--   3. Trigger function is SECURITY DEFINER so pg_net HTTP privileges
--      are not required from the caller role (anon / authenticated).
-- =====================================================================

-- 1. pg_net extension (idempotent; already installed in `extensions` schema
--    on this project per list_extensions inspection, but keep the statement
--    here so future `supabase db push` against a fresh replica also works).
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Idempotency guard column on orders.
--    `IF NOT EXISTS` is essential here because this migration must be
--    re-runnable (Task 8 will re-apply idempotently as a smoke test).
ALTER TABLE IF EXISTS public.orders
    ADD COLUMN IF NOT EXISTS notifications_attempted boolean NOT NULL DEFAULT false;

-- 3. Partial index so the trigger + any future maintenance scans can
--    quickly find rows still pending the notification attempt.
--    Size: ~0 rows initially since 99% of orders eventually flip to true.
CREATE INDEX IF NOT EXISTS idx_orders_notifications_attempted_pending
    ON public.orders (id)
    WHERE notifications_attempted = false;

-- =====================================================================
-- Trigger function: queue_new_order_notification
-- Called AFTER INSERT and AFTER UPDATE on `orders`.
-- Fires `new-order-notify` edge function at most once per order.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.queue_new_order_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
-- SET search_path explicitly so SECURITY DEFINER does not pick up an
-- attacker-controlled search path from the session (hardening).
SET search_path = public, extensions, pg_catalog
AS $$
DECLARE
    _flipped integer;
    _is_paid boolean;
    _edge_url text;
    _anon_key text;
    _body jsonb;
BEGIN
    -- -----------------------------------------------------------------
    -- Fast-path 1: already attempted (concurrent caller or prior run).
    -- This is redundant with the conditional UPDATE below, but cheap.
    -- -----------------------------------------------------------------
    IF NEW.notifications_attempted THEN
        RETURN NEW;
    END IF;

    -- -----------------------------------------------------------------
    -- Fast-path 2: not yet paid / no-store (no notification warranted).
    -- An order is "paid enough" for notifications when EITHER:
    --   (a) payment_status is 'completed' (Paystack, card), OR
    --   (b) payment_method is a COD-style offline method where the
    --       status advances straight to awaiting_store_acceptance
    --       without a webhook.
    -- -----------------------------------------------------------------
    _is_paid := (
        lower(coalesce(NEW.payment_status, '')) = 'completed'
        OR lower(trim(coalesce(NEW.payment_method, ''))) IN (
            'cash','cod','cash_on_delivery','card_on_delivery',
            'speed_point','speedpoint','eft','in_store'
        )
    );

    IF NOT _is_paid OR NEW.store_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- -----------------------------------------------------------------
    -- Atomic idempotency flip.
    -- Only ONE concurrent caller (this trigger OR the client-side
    -- `payment_service.dart` invocation OR the Paystack webhook) will
    -- see a row count of 1.  Everyone else short-circuits here.
    -- -----------------------------------------------------------------
    UPDATE public.orders
       SET notifications_attempted = true
     WHERE id = NEW.id
       AND notifications_attempted = false;

    GET DIAGNOSTICS _flipped = ROW_COUNT;

    IF _flipped <> 1 THEN
        -- Another process already claimed this order's notification.
        RETURN NEW;
    END IF;

    -- -----------------------------------------------------------------
    -- Fire the edge function asynchronously via pg_net.
    -- pg_net queues the HTTP call and returns immediately (non-blocking).
    -- If the HTTP POST fails, the queue retries per pg_net's policy.
    -- -----------------------------------------------------------------
    -- NOTE: SUPABASE_URL + anon key are embedded here for the DB-side
    -- caller. They are the SAME public values used by the Flutter apps
    -- (i.e. NOT secrets -- the anon key is bundled in every client).
    -- The `new-order-notify` edge function ALSO performs an independent
    -- check that payment_status = 'completed' before sending FCM, so
    -- even if the WHEN clauses above are permissive, the edge FSM
    -- remains the final authority (belt + suspenders).
    _edge_url := 'https://lxsvydiyzeavdqbjxkpp.supabase.co/functions/v1/new-order-notify';
    _anon_key := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4c3Z5ZGl5emVhdmRxYmp4a3BwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc3Njg1MDQsImV4cCI6MjA4MzM0NDUwNH0.nThX1Mj5MlKbsCsmlW8RhukSXC57kcbB9za92LwwiDQ';

    _body := jsonb_build_object(
        'order_id',   NEW.id::text,
        'store_id',   NEW.store_id::text
    );

    -- fire-and-forget; return value (request_id bigint) is intentionally
    -- discarded. pg_net exposes `net.http_request_queue` if we ever need
    -- to investigate stuck deliveries.
    PERFORM extensions.net.http_post(
        url         := _edge_url,
        body        := _body::text,
        headers     := format(
            '{"Content-Type":"application/json","Authorization":"Bearer %s"}',
            _anon_key
        )::jsonb
    );

    RETURN NEW;
END;
$$;

-- Tighten permissions on the SECURITY DEFINER function so arbitrary DB
-- roles cannot invoke it directly.
REVOKE ALL ON FUNCTION public.queue_new_order_notification() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.queue_new_order_notification() TO postgres, anon, authenticated, service_role;

-- =====================================================================
-- AFTER INSERT trigger: covers the happy path where the order is
-- created already-paid (e.g. COD) or where the client-side call was
-- skipped but the row already landed in a paid state.
-- =====================================================================
DROP TRIGGER IF EXISTS orders_after_insert_notify ON public.orders;
CREATE TRIGGER orders_after_insert_notify
    AFTER INSERT ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION public.queue_new_order_notification();

-- =====================================================================
-- AFTER UPDATE trigger: covers Paystack webhook / split-verification
-- flows where the order is first INSERTED as payment_status='pending'
-- and then UPDATED to 'completed' seconds later when the webhook hits.
-- WHEN clause is permissive; the function body + guard column do all
-- the real filtering.
-- =====================================================================
DROP TRIGGER IF EXISTS orders_after_update_notify ON public.orders;
CREATE TRIGGER orders_after_update_notify
    AFTER UPDATE OF payment_status, payment_method, status
    ON public.orders
    FOR EACH ROW
    WHEN (
        -- Case A: payment just transitioned to completed
        (OLD.payment_status IS DISTINCT FROM 'completed' AND lower(NEW.payment_status) = 'completed')
        OR
        -- Case B: order advanced to awaiting_store_acceptance but the
        --         notification guard was never flipped (covers the
        --         scenario where payment never reaches 'completed' for
        --         an offline method but the order is active)
        (NEW.status = 'awaiting_store_acceptance' AND NOT NEW.notifications_attempted
         AND OLD.status IS DISTINCT FROM 'awaiting_store_acceptance')
    )
    EXECUTE FUNCTION public.queue_new_order_notification();
