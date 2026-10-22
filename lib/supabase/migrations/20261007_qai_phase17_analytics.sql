-- ============================================================================
-- Phase 17 — Analytics & AI Evaluation
--
-- Roadmap scope (§21):
--   Engagement:      AI queries, tool calls, clicks, recommendation CTR,
--                    AI -> cart, AI -> order conversion, avg basket value.
--   Quality:         incorrect_*_rate, hallucination_reports, tool_failure,
--                    response_latency, user feedback (thumbs up/down + note).
--   Infrastructure:  ai_cart_events bridge already exists (Phase 16 §3.1).
--                     This migration adds:
--   1. ai_query_events    — every AI turn (latency, tool rounds, card counts).
--   2. ai_quality_feedback — user thumbs up/down + optional free-text note.
--   3. Orders-from-AI     — bridge column orders.ai_assisted BOOL,
--                           set when user hits checkout via AI chat flow.
--   4. qai_record_query_event + qai_submit_feedback helpers.
--
-- Policies:   Owner-only SELECT/INSERT (RLS). Service role has FULL access.
--
-- SSOT notes:
--   Latency is ms (int) between user sending message and assistant returning.
--   Conversations are optional (null == anon/unlinked session, still counted).
--   Incident type enum lets us filter for "incorrect_price" etc.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ai_query_events — every AI turn (engagement + performance bookkeeping).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_query_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
    conversation_id uuid REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
    message_id uuid,
    intent text,
    query_chars integer,
    response_chars integer,
    latency_ms integer,
    tool_rounds smallint,
    product_cards smallint DEFAULT 0,
    store_cards smallint DEFAULT 0,
    recipe_cards smallint DEFAULT 0,
    plan_cards smallint DEFAULT 0,
    basket_cards smallint DEFAULT 0,
    store_option_cards smallint DEFAULT 0,
    has_cart_proposal boolean DEFAULT FALSE,
    tool_names text[] NOT NULL DEFAULT '{}'::text[],
    tool_failures jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','tool_error','llm_error','rate_limited','aborted')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ai_query_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_query_events_owner_select ON public.ai_query_events;
CREATE POLICY ai_query_events_owner_select ON public.ai_query_events
    FOR SELECT USING (auth.uid() = user_id OR user_id IS NULL);

DROP POLICY IF EXISTS ai_query_events_owner_insert ON public.ai_query_events;
CREATE POLICY ai_query_events_owner_insert ON public.ai_query_events
    FOR INSERT WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

GRANT SELECT, INSERT ON public.ai_query_events TO authenticated, anon;
GRANT ALL ON public.ai_query_events TO service_role;

CREATE INDEX IF NOT EXISTS ai_query_events_user_time_idx
    ON public.ai_query_events (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_query_events_created_idx
    ON public.ai_query_events (created_at DESC);
CREATE INDEX IF NOT EXISTS ai_query_events_status_idx
    ON public.ai_query_events (status) WHERE status <> 'ok';

COMMENT ON TABLE  public.ai_query_events IS 'Phase 17 — per-turn AI telemetry: latency, tool rounds, card counts, errors. Foundation for CTR and conversion-rate analytics downstream.';
COMMENT ON COLUMN public.ai_query_events.latency_ms         IS 'Total wall-clock ms between user POST and assistant response in the same turn.';
COMMENT ON COLUMN public.ai_query_events.product_cards      IS 'COUNT(cards.products) — used for recommendation CTR when joined with product clicks.';
COMMENT ON COLUMN public.ai_query_events.has_cart_proposal  IS 'TRUE when the turn emitted a cards.cartProposal — denominator for AI->cart conversion.';

-- ----------------------------------------------------------------------------
-- 2. ai_quality_feedback — user thumbs and hallucination / bad-result reports.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_quality_feedback (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    conversation_id uuid REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
    message_id uuid,
    polarity text NOT NULL CHECK (polarity IN ('up','down')),
    incident_type text CHECK (incident_type IN (
        'incorrect_product',
        'incorrect_price',
        'incorrect_store',
        'hallucination',
        'bad_recommendation',
        'unhelpful',
        'offensive',
        'other'
    )),
    note text,
    reported_card jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ai_quality_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_quality_feedback_owner_select ON public.ai_quality_feedback;
CREATE POLICY ai_quality_feedback_owner_select ON public.ai_quality_feedback
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_quality_feedback_owner_insert ON public.ai_quality_feedback;
CREATE POLICY ai_quality_feedback_owner_insert ON public.ai_quality_feedback
    FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_quality_feedback_owner_update ON public.ai_quality_feedback;
CREATE POLICY ai_quality_feedback_owner_update ON public.ai_quality_feedback
    FOR UPDATE USING (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE (polarity, incident_type, note, reported_card, metadata)
    ON public.ai_quality_feedback TO authenticated;
GRANT ALL ON public.ai_quality_feedback TO service_role;

CREATE INDEX IF NOT EXISTS ai_quality_feedback_user_time_idx
    ON public.ai_quality_feedback (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_quality_feedback_conv_msg_idx
    ON public.ai_quality_feedback (conversation_id, message_id);
CREATE INDEX IF NOT EXISTS ai_quality_feedback_polarity_idx
    ON public.ai_quality_feedback (polarity, created_at DESC);

COMMENT ON TABLE  public.ai_quality_feedback IS 'Phase 17 — explicit user thumbs up/down + optional incident report on any assistant bubble.';
COMMENT ON COLUMN public.ai_quality_feedback.polarity     IS 'up = helpful, down = unhelpful / wrong.';
COMMENT ON COLUMN public.ai_quality_feedback.incident_type IS 'Free-text classification from an enum set; UI presents a small chip menu.';
COMMENT ON COLUMN public.ai_quality_feedback.reported_card IS 'Optional snapshot of the cards.* payload the user was seeing when they reported feedback.';

-- ----------------------------------------------------------------------------
-- 3. Orders-from-AI bridge column (denominator for AI -> order conversion).
--    Set TRUE when the app routes the user from the AI chat into checkout with
--    items that were added via the assistant (ai_assisted basket flag below).
-- ----------------------------------------------------------------------------
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ai_assisted boolean NOT NULL DEFAULT FALSE;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ai_conversation_id uuid
    REFERENCES public.ai_conversations(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.orders.ai_assisted         IS 'Phase 17 — TRUE if at least one cart item was added via the Q AI assistant flow. Used for AI -> order conversion and avg AI-assisted basket value metrics.';
COMMENT ON COLUMN public.orders.ai_conversation_id  IS 'Phase 17 — conversation this order originated from (optional, set by the Flutter checkout handoff).';

-- ----------------------------------------------------------------------------
-- 4. Helpers
-- ----------------------------------------------------------------------------

-- 4.1  qai_record_query_event(...) -> event_id
CREATE OR REPLACE FUNCTION public.qai_record_query_event(
    p_conversation_id  uuid    DEFAULT NULL,
    p_message_id       uuid    DEFAULT NULL,
    p_intent           text    DEFAULT NULL,
    p_query_chars      integer DEFAULT NULL,
    p_response_chars   integer DEFAULT NULL,
    p_latency_ms       integer DEFAULT NULL,
    p_tool_rounds      smallint DEFAULT NULL,
    p_product_cards    smallint DEFAULT NULL,
    p_store_cards      smallint DEFAULT NULL,
    p_recipe_cards     smallint DEFAULT NULL,
    p_plan_cards       smallint DEFAULT NULL,
    p_basket_cards     smallint DEFAULT NULL,
    p_store_option_cards smallint DEFAULT NULL,
    p_has_cart_proposal boolean DEFAULT NULL,
    p_tool_names       text[]   DEFAULT NULL,
    p_tool_failures    jsonb    DEFAULT NULL,
    p_status           text     DEFAULT 'ok',
    p_metadata         jsonb    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_eid uuid;
BEGIN
    INSERT INTO public.ai_query_events (
        user_id, conversation_id, message_id, intent,
        query_chars, response_chars, latency_ms, tool_rounds,
        product_cards, store_cards, recipe_cards, plan_cards,
        basket_cards, store_option_cards, has_cart_proposal,
        tool_names, tool_failures, status, metadata
    ) VALUES (
        auth.uid(),
        p_conversation_id,
        p_message_id,
        p_intent,
        CASE WHEN p_query_chars    >= 0 THEN p_query_chars    ELSE NULL END,
        CASE WHEN p_response_chars >= 0 THEN p_response_chars ELSE NULL END,
        CASE WHEN p_latency_ms     >= 0 THEN p_latency_ms     ELSE NULL END,
        CASE WHEN p_tool_rounds    >= 0 THEN p_tool_rounds    ELSE NULL END,
        CASE WHEN p_product_cards    >= 0 THEN p_product_cards    ELSE 0 END,
        CASE WHEN p_store_cards      >= 0 THEN p_store_cards      ELSE 0 END,
        CASE WHEN p_recipe_cards     >= 0 THEN p_recipe_cards     ELSE 0 END,
        CASE WHEN p_plan_cards       >= 0 THEN p_plan_cards       ELSE 0 END,
        CASE WHEN p_basket_cards     >= 0 THEN p_basket_cards     ELSE 0 END,
        CASE WHEN p_store_option_cards >= 0 THEN p_store_option_cards ELSE 0 END,
        COALESCE(p_has_cart_proposal, FALSE),
        COALESCE(p_tool_names,    '{}'::text[]),
        COALESCE(p_tool_failures, '{}'::jsonb),
        CASE WHEN p_status IN ('ok','tool_error','llm_error','rate_limited','aborted')
             THEN p_status ELSE 'ok' END,
        COALESCE(p_metadata, '{}'::jsonb)
    ) RETURNING id INTO v_eid;
    RETURN v_eid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_record_query_event(uuid,uuid,text,integer,integer,integer,smallint,smallint,smallint,smallint,smallint,smallint,smallint,boolean,text[],jsonb,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_record_query_event(uuid,uuid,text,integer,integer,integer,smallint,smallint,smallint,smallint,smallint,smallint,smallint,boolean,text[],jsonb,text,jsonb) TO authenticated, anon;

COMMENT ON FUNCTION public.qai_record_query_event(uuid,uuid,text,integer,integer,integer,smallint,smallint,smallint,smallint,smallint,smallint,smallint,boolean,text[],jsonb,text,jsonb)
IS 'Phase 17 — insert a per-turn query event. Returns the new event id. Safe to call from anon context (user_id becomes NULL for unauthed telemetry).';

-- 4.2  qai_submit_feedback(...) -> feedback_id
CREATE OR REPLACE FUNCTION public.qai_submit_feedback(
    p_conversation_id uuid DEFAULT NULL,
    p_message_id      uuid DEFAULT NULL,
    p_polarity        text DEFAULT 'up',
    p_incident_type   text DEFAULT NULL,
    p_note            text DEFAULT NULL,
    p_reported_card   jsonb DEFAULT NULL,
    p_metadata        jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_uid uuid;
    v_fid uuid;
    v_pol text;
    v_inc text;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN NULL;
    END IF;
    v_pol := CASE WHEN lower(p_polarity) = 'down' THEN 'down' ELSE 'up' END;
    IF p_incident_type IS NOT NULL AND p_incident_type IN (
        'incorrect_product','incorrect_price','incorrect_store',
        'hallucination','bad_recommendation','unhelpful','offensive','other'
    ) THEN
        v_inc := p_incident_type;
    ELSE
        v_inc := NULL;
    END IF;

    INSERT INTO public.ai_quality_feedback (
        user_id, conversation_id, message_id, polarity,
        incident_type, note, reported_card, metadata
    ) VALUES (
        v_uid,
        p_conversation_id,
        p_message_id,
        v_pol,
        v_inc,
        p_note,
        p_reported_card,
        COALESCE(p_metadata, '{}'::jsonb)
    ) RETURNING id INTO v_fid;

    RETURN v_fid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_submit_feedback(uuid,uuid,text,text,text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_submit_feedback(uuid,uuid,text,text,text,jsonb,jsonb) TO authenticated;

COMMENT ON FUNCTION public.qai_submit_feedback(uuid,uuid,text,text,text,jsonb,jsonb)
IS 'Phase 17 — record a thumbs-up/down + optional incident report. Returns feedback id or NULL on RLS failure.';

-- ----------------------------------------------------------------------------
-- 5. ai_cart_events — AI -> cart -> checkout funnel bridge.
--    Event types: cart_items_added | checkout_handoff
--    Carries conversation_id so a delivered order can be traced back to the
--    exact AI turn that built the basket.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_cart_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    conversation_id uuid REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
    store_id uuid REFERENCES public.stores(id) ON DELETE SET NULL,
    event_type text NOT NULL CHECK (event_type IN ('cart_proposed','cart_items_added','checkout_handoff')),
    product_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
    item_count integer,
    total_cost numeric(10,2),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ai_cart_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_cart_events_owner_select ON public.ai_cart_events;
CREATE POLICY ai_cart_events_owner_select ON public.ai_cart_events
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_cart_events_owner_insert ON public.ai_cart_events;
CREATE POLICY ai_cart_events_owner_insert ON public.ai_cart_events
    FOR INSERT WITH CHECK (auth.uid() = user_id);

GRANT SELECT, INSERT ON public.ai_cart_events TO authenticated;
GRANT ALL ON public.ai_cart_events TO service_role;

CREATE INDEX IF NOT EXISTS ai_cart_events_user_time_idx
    ON public.ai_cart_events (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_cart_events_conv_idx
    ON public.ai_cart_events (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_cart_events_store_idx
    ON public.ai_cart_events (store_id, created_at DESC);

COMMENT ON TABLE  public.ai_cart_events IS 'Phase 17 — AI-cart-to-checkout funnel bridge. The CTR denominator for AI->cart and AI->order conversion.';
COMMENT ON COLUMN public.ai_cart_events.event_type  IS 'cart_items_added = AI CTA tapped, checkout_handoff = user entered the checkout screen.';

-- 5.1  qai_record_cart_event(...) -> event_id
CREATE OR REPLACE FUNCTION public.qai_record_cart_event(
    p_event_type      text,
    p_store_id        uuid   DEFAULT NULL,
    p_product_ids     uuid[] DEFAULT NULL,
    p_total_cost      numeric DEFAULT NULL,
    p_items           integer DEFAULT NULL,
    p_conversation_id uuid   DEFAULT NULL,
    p_metadata        jsonb  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_uid uuid;
    v_eid uuid;
    v_et text;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RETURN NULL; END IF;
    v_et := CASE lower(p_event_type)
                 WHEN 'cart_proposed'     THEN 'cart_proposed'
                 WHEN 'checkout_handoff' THEN 'checkout_handoff'
                 ELSE 'cart_items_added'
            END;
    INSERT INTO public.ai_cart_events (
        user_id, conversation_id, store_id, event_type,
        product_ids, item_count, total_cost, metadata
    ) VALUES (
        v_uid,
        p_conversation_id,
        p_store_id,
        v_et,
        COALESCE(p_product_ids, '{}'::uuid[]),
        CASE WHEN p_items >= 0 THEN p_items ELSE NULL END,
        CASE WHEN p_total_cost >= 0 THEN p_total_cost ELSE NULL END,
        COALESCE(p_metadata, '{}'::jsonb)
    ) RETURNING id INTO v_eid;
    RETURN v_eid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_record_cart_event(text,uuid,uuid[],numeric,integer,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_record_cart_event(text,uuid,uuid[],numeric,integer,uuid,jsonb) TO authenticated;

COMMENT ON FUNCTION public.qai_record_cart_event(text,uuid,uuid[],numeric,integer,uuid,jsonb)
IS 'Phase 17 — insert cart_items_added or checkout_handoff. Returns event id or NULL if unauthenticated.';

-- ----------------------------------------------------------------------------
-- 6. KPI analytics RPCs (service-role / SECURITY DEFINER).
--    All accept p_days (default 30) and return 1-row summaries suitable for
--    an admin dashboard or scheduled weekly email.
-- ----------------------------------------------------------------------------

-- 6.1  Engagement: DAU, AI queries per DAU, engagement rate.
CREATE OR REPLACE FUNCTION public.qai_kpi_engagement(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    dau bigint,
    ai_query_users bigint,
    ai_query_count bigint,
    engagement_rate numeric,
    queries_per_user numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(DISTINCT user_id) FROM public.orders WHERE created_at >= v_start) AS dau,
        (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start) AS ai_query_users,
        (SELECT count(*) FROM public.ai_query_events WHERE created_at >= v_start) AS ai_query_count,
        CASE WHEN (SELECT count(DISTINCT user_id) FROM public.orders WHERE created_at >= v_start) > 0
             THEN round(
                (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start)::numeric /
                (SELECT count(DISTINCT user_id) FROM public.orders WHERE created_at >= v_start)::numeric, 4)
             ELSE 0 END AS engagement_rate,
        CASE WHEN (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start) > 0
             THEN round(
                (SELECT count(*)::numeric FROM public.ai_query_events WHERE created_at >= v_start) /
                (SELECT count(DISTINCT user_id)::numeric FROM public.ai_query_events WHERE created_at >= v_start), 2)
             ELSE 0 END AS queries_per_user;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_engagement(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_engagement(integer) TO service_role;

-- 6.2  Recommendation CTR (home-screen For-You / Picked-For-You rails).
CREATE OR REPLACE FUNCTION public.qai_kpi_recommendation_ctr(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    rec_shown bigint,
    rec_clicked bigint,
    ctr numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(*) FROM public.ai_events WHERE event_type = 'recommendation_shown' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_events WHERE event_type = 'recommendation_clicked' AND created_at >= v_start),
        CASE WHEN (SELECT count(*) FROM public.ai_events WHERE event_type = 'recommendation_shown' AND created_at >= v_start) > 0
             THEN round(
                (SELECT count(*)::numeric FROM public.ai_events WHERE event_type = 'recommendation_clicked' AND created_at >= v_start) /
                (SELECT count(*)::numeric FROM public.ai_events WHERE event_type = 'recommendation_shown' AND created_at >= v_start), 4)
             ELSE 0 END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_recommendation_ctr(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_recommendation_ctr(integer) TO service_role;

-- 6.3  AI -> cart conversion: users who chatted vs users who tapped an AI
--      cart CTA (cart_items_added) within the window.
CREATE OR REPLACE FUNCTION public.qai_kpi_ai_to_cart_conversion(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    ai_query_users bigint,
    ai_cart_users bigint,
    conversion_rate numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start),
        (SELECT count(DISTINCT user_id) FROM public.ai_cart_events WHERE event_type = 'cart_items_added' AND created_at >= v_start),
        CASE WHEN (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start) > 0
             THEN round(
                (SELECT count(DISTINCT user_id)::numeric FROM public.ai_cart_events WHERE event_type = 'cart_items_added' AND created_at >= v_start) /
                (SELECT count(DISTINCT user_id)::numeric FROM public.ai_query_events WHERE created_at >= v_start), 4)
             ELSE 0 END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_ai_to_cart_conversion(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_ai_to_cart_conversion(integer) TO service_role;

-- 6.4  AI -> order conversion: chat users vs AI-assisted delivered orders.
CREATE OR REPLACE FUNCTION public.qai_kpi_ai_to_order_conversion(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    ai_query_users bigint,
    ai_delivered_users bigint,
    ai_delivered_orders bigint,
    conversion_rate numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start),
        (SELECT count(DISTINCT user_id) FROM public.orders WHERE ai_assisted = TRUE AND status = 'delivered' AND created_at >= v_start),
        (SELECT count(*) FROM public.orders WHERE ai_assisted = TRUE AND status = 'delivered' AND created_at >= v_start),
        CASE WHEN (SELECT count(DISTINCT user_id) FROM public.ai_query_events WHERE created_at >= v_start) > 0
             THEN round(
                (SELECT count(DISTINCT user_id)::numeric FROM public.orders WHERE ai_assisted = TRUE AND status = 'delivered' AND created_at >= v_start) /
                (SELECT count(DISTINCT user_id)::numeric FROM public.ai_query_events WHERE created_at >= v_start), 4)
             ELSE 0 END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_ai_to_order_conversion(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_ai_to_order_conversion(integer) TO service_role;

-- 6.5  Recipe -> cart: recipe views/recipe-events vs basket-add CTAs.
CREATE OR REPLACE FUNCTION public.qai_kpi_recipe_to_cart(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    recipe_interactions bigint,
    basket_added_events bigint,
    conversion_rate numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(*) FROM public.ai_events
          WHERE event_type IN ('recipe_viewed','recipe_ingredient_clicked') AND created_at >= v_start)
        + (SELECT count(*) FROM public.ai_query_events WHERE recipe_cards > 0 AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_cart_events
          WHERE event_type = 'cart_items_added'
            AND (metadata ->> 'kind') IN ('recipe_basket','recipe_basket_ingredient')
            AND created_at >= v_start),
        CASE WHEN
            (
              (SELECT count(*) FROM public.ai_events
                WHERE event_type IN ('recipe_viewed','recipe_ingredient_clicked') AND created_at >= v_start)
              + (SELECT count(*) FROM public.ai_query_events WHERE recipe_cards > 0 AND created_at >= v_start)
            ) > 0
        THEN round(
            (SELECT count(*)::numeric FROM public.ai_cart_events
              WHERE event_type = 'cart_items_added'
                AND (metadata ->> 'kind') IN ('recipe_basket','recipe_basket_ingredient')
                AND created_at >= v_start)
            /
            (
              (SELECT count(*)::numeric FROM public.ai_events
                WHERE event_type IN ('recipe_viewed','recipe_ingredient_clicked') AND created_at >= v_start)
              + (SELECT count(*)::numeric FROM public.ai_query_events WHERE recipe_cards > 0 AND created_at >= v_start)
            ), 4)
        ELSE 0 END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_recipe_to_cart(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_recipe_to_cart(integer) TO service_role;

-- 6.6  Repeat-order conversion: home-screen "Order Again" clicks to delivered.
CREATE OR REPLACE FUNCTION public.qai_kpi_repeat_order(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    repeat_order_clicks bigint,
    repeat_order_delivered bigint,
    conversion_rate numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(*) FROM public.ai_events WHERE event_type = 'order_again_clicked' AND created_at >= v_start),
        (SELECT count(*)
           FROM public.orders o
           JOIN public.ai_events e ON e.user_id = o.user_id
          WHERE e.event_type = 'order_again_clicked'
            AND e.created_at >= v_start
            AND o.status = 'delivered'
            AND o.created_at BETWEEN e.created_at AND e.created_at + interval '7 days'),
        CASE WHEN (SELECT count(*) FROM public.ai_events WHERE event_type = 'order_again_clicked' AND created_at >= v_start) > 0
             THEN round(
                (SELECT count(*)::numeric
                   FROM public.orders o
                   JOIN public.ai_events e ON e.user_id = o.user_id
                  WHERE e.event_type = 'order_again_clicked'
                    AND e.created_at >= v_start
                    AND o.status = 'delivered'
                    AND o.created_at BETWEEN e.created_at AND e.created_at + interval '7 days')
                /
                (SELECT count(*)::numeric FROM public.ai_events WHERE event_type = 'order_again_clicked' AND created_at >= v_start), 4)
             ELSE 0 END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_repeat_order(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_repeat_order(integer) TO service_role;

-- 6.7  Average AI-assisted basket value (subtotal only, excl. fees).
CREATE OR REPLACE FUNCTION public.qai_kpi_avg_ai_basket(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    ai_assisted_baskets bigint,
    avg_subtotal numeric,
    total_gmv numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        count(*),
        round(avg(COALESCE(discount_total, subtotal, 0))::numeric, 2),
        round(sum(COALESCE(discount_total, subtotal, 0))::numeric, 2)
    FROM public.orders
    WHERE ai_assisted = TRUE AND created_at >= v_start;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_avg_ai_basket(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_avg_ai_basket(integer) TO service_role;

-- 6.8  AI quality summary: feedback, incidents, tool failure rate, latency.
CREATE OR REPLACE FUNCTION public.qai_kpi_ai_quality(p_days integer DEFAULT 30)
RETURNS TABLE(
    window_days integer,
    feedback_up bigint,
    feedback_down bigint,
    incorrect_product_count bigint,
    incorrect_price_count bigint,
    incorrect_store_count bigint,
    hallucination_count bigint,
    bad_recommendation_count bigint,
    tool_error_events bigint,
    avg_latency_ms integer,
    p95_latency_ms integer
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_start timestamptz := now() - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        p_days,
        (SELECT count(*) FROM public.ai_quality_feedback WHERE polarity = 'up' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE polarity = 'down' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE incident_type = 'incorrect_product' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE incident_type = 'incorrect_price' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE incident_type = 'incorrect_store' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE incident_type = 'hallucination' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_quality_feedback WHERE incident_type = 'bad_recommendation' AND created_at >= v_start),
        (SELECT count(*) FROM public.ai_query_events WHERE status = 'tool_error' AND created_at >= v_start),
        COALESCE((SELECT round(avg(latency_ms))::integer FROM public.ai_query_events WHERE latency_ms IS NOT NULL AND created_at >= v_start), 0),
        COALESCE((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)::integer
                    FROM public.ai_query_events WHERE latency_ms IS NOT NULL AND created_at >= v_start), 0);
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_kpi_ai_quality(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_kpi_ai_quality(integer) TO service_role;

-- ----------------------------------------------------------------------------
-- 7. AI -> order funnel closure: when an ai_assisted order reaches DELIVERED,
--    stamp a high-signal event back into ai_events so the affinity rebuild
--    sees it the same way a normal product_added/order_completed would.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_trg_mark_ai_order_delivered()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
    IF (TG_OP = 'UPDATE'
        AND OLD.status IS DISTINCT FROM NEW.status
        AND NEW.status = 'delivered'
        AND NEW.ai_assisted = TRUE
        AND NEW.user_id IS NOT NULL)
    THEN
        BEGIN
            INSERT INTO public.ai_events (
                user_id, event_type, entity_type, entity_id, metadata
            ) VALUES (
                NEW.user_id,
                'order_completed',
                'order',
                NEW.id::text,
                jsonb_build_object(
                    'store_id', NEW.store_id,
                    'total', NEW.discount_total,
                    'ai_conversation_id', NEW.ai_conversation_id,
                    'ai_assisted', TRUE,
                    'via', 'phase17_trigger'
                )
            );
        EXCEPTION WHEN OTHERS THEN
            -- alerts-incident rule: analytics never break an order update.
            RAISE WARNING 'qai_trg_mark_ai_order_delivered failed: %', SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS qai_orders_ai_delivered_trg ON public.orders;
CREATE TRIGGER qai_orders_ai_delivered_trg
AFTER UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.qai_trg_mark_ai_order_delivered();
