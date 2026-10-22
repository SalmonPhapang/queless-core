-- =====================================================================
-- Migration: 20261011_add_dispatch_notification_push
-- Purpose: Push FCM for server-originated order notifications, in particular
--          the "finding you another driver" notification (data->>'event' =
--          'dispatch_offer_expired') written by
--          public.enforce_dispatch_offer_timeout().
--
-- Strategy (clones the existing queue_new_order_notification pattern from
-- 20260908_notifications_trigger_guards.sql):
--   1. pg_net extension (idempotent).
--   2. SECURITY DEFINER trigger function that fires the dispatchnotify edge
--      function over pg_net.http_post, passing the anon key in the Auth header.
--   3. AFTER INSERT trigger on public.notifications, filtered to the event
--      types we push (currently only dispatch_offer_expired).
--   4. Idempotent: DROP TRIGGER IF EXISTS / CREATE TRIGGER, CREATE OR REPLACE
--      FUNCTION.
--
-- The edge function (supabase/functions/dispatchnotify) does the actual FCM
-- send. This trigger only queues the HTTP call — it never blocks the INSERT,
-- and if the push fails the notification row is already durable in the inbox.
-- =====================================================================

-- 1. pg_net extension (idempotent).
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Trigger function: queue_dispatch_notification
--    Fires the dispatchnotify edge function for notification rows that are
--    customer-facing order pushes (currently: dispatch_offer_expired).
--    Ignores everything else (driver notifications, etc.) so we never push
--    on behalf of a notification we didn't author.
CREATE OR REPLACE FUNCTION public.queue_dispatch_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_catalog
AS $$
DECLARE
    _edge_url text;
    _anon_key text;
    _body jsonb;
    _event text;
    _type text;
BEGIN
    -- Only push customer-facing order notifications we recognise.
    _type := lower(coalesce(NEW.type, ''));
    _event := lower(coalesce((NEW.data ->> 'event')::text, ''));

    -- Currently the only recognised pushable event is the dispatch offer expiry
    -- ('finding you another driver'). Add more here as the server emits more
    -- customer-facing notification events that warrant a push.
    IF _type <> 'order' OR _event <> 'dispatch_offer_expired' THEN
        RETURN NEW;
    END IF;

    -- The dispatchnotify edge function reads the full row itself and decides
    -- whether to push (it also re-checks the event). We pass just the row id
    -- so the trigger body stays small and the edge function is the single place
    -- that builds the FCM message.
    _edge_url := 'https://lxsvydiyzeavdqbjxkpp.supabase.co/functions/v1/dispatchnotify';
    _anon_key := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4c3Z5ZGl5emVhdmRxYmp4a3BwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc3Njg1MDQsImV4cCI6MjA4MzM0NDUwNH0.nThX1Mj5MlKbsCsmlW8RhukSXC57kcbB9za92LwwiDQ';

    _body := jsonb_build_object('id', NEW.id::text);

    -- fire-and-forget via pg_net; the return value (request_id) is discarded.
    -- If the HTTP POST fails, pg_net retries per its policy; the notification
    -- row is already durable, so a missed push just means the customer sees it
    -- on next open rather than getting a heads-up.
    PERFORM extensions.net.http_post(
        url := _edge_url,
        body := _body::text,
        headers := format('{"Content-Type":"application/json","Authorization":"Bearer %s"}', _anon_key)::jsonb
    );

    RETURN NEW;
END;
$$;

-- Tighten permissions on the SECURITY DEFINER function.
REVOKE ALL ON FUNCTION public.queue_dispatch_notification() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_dispatch_notification() TO postgres, anon, authenticated, service_role;

-- 3. AFTER INSERT trigger on notifications.
--    This is the FIRST trigger on the notifications table. There is currently
--    no other trigger here (the orders-status / order-status-notify /
--    new-order-notify functions write rows directly; nothing reacts to the insert).
DROP TRIGGER IF EXISTS notifications_after_insert_dispatch_push ON public.notifications;
CREATE TRIGGER notifications_after_insert_dispatch_push
    AFTER INSERT ON public.notifications
    FOR EACH ROW
    EXECUTE FUNCTION public.queue_dispatch_notification();

-- Idempotent backstop: if the function is later replaced with a stricter
-- version, recompute. (No-op today; future-proofing the re-run path.)
-- Nothing to reset here: the trigger is FOR EACH ROW and only fires on INSERT,
-- so a re-run does not replay historical rows.

-- Done.
