-- ============================================================================
-- Phase 18 — Security & Privacy
--
-- Roadmap scope (§22):
--   ✓ RLS on all customer tables            — verified.
--   ✓ Authenticated edge functions          — verify_jwt on ai-chat.
--   1. No client-supplied customer IDs      — harden SECURITY DEFINER RPCs.
--   2. Input / output validation            — enforced server-side in edge fn.
--   3. Rate limiting                        — daily cap live; add retention.
--   4. Prompt-injection protection          — system prompt hardening.
--   5. Tool authorization                   — userId always from server.
--   ✓ Payment data isolation                — payments RLS, no LLM touch.
--   ✓ No secrets in prompts                 — env only.
--   6. No unnecessary PII sent to LLM       — PII minimization in fn.
--   7. Conversation retention policy        — purge RPC + schedule config.
--   8. AI event retention policy            — purge RPC + schedule config.
--   9. Admin audit logging                  — audit table + RPC + triggers.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SECURITY: Harden SECURITY DEFINER RPCs that accept a p_user_id param.
--    Client-supplied p_user_id is IGNORED for authed callers.
-- ----------------------------------------------------------------------------

-- 1.1  qai_usual_order — previously trusted p_user_id.
--      Flutter still passes the session user (expected); we now overwrite it.
CREATE OR REPLACE FUNCTION public.qai_usual_order(
  p_user_id uuid
)
RETURNS TABLE (
  order_id uuid,
  order_number text,
  store_id uuid,
  store_name text,
  store_image text,
  store_open boolean,
  original_total numeric,
  current_subtotal numeric,
  unavailable_count integer,
  items jsonb
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid uuid;
  v_order record;
  v_items jsonb;
  v_unavailable integer := 0;
  v_subtotal numeric := 0;
BEGIN
  -- NEVER trust a caller-supplied user id for a customer-scoped RPC.
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  SELECT o.id, o.order_number, o.store_id, o.total, o.items
  INTO v_order
  FROM public.orders o
  WHERE o.user_id = v_uid
    AND o.status IN ('delivered', 'completed')
    AND jsonb_typeof(o.items) = 'array'
    AND jsonb_array_length(o.items) > 0
  ORDER BY o.created_at DESC
  LIMIT 1;

  IF v_order.id IS NULL THEN
    RETURN;
  END IF;

  SELECT COALESCE(jsonb_agg(repriced ORDER BY repriced->>'product_name'), '[]'::jsonb),
         count(*) FILTER (WHERE (repriced->>'available')::boolean = false)
  INTO v_items, v_unavailable
  FROM (
    SELECT jsonb_build_object(
      'product_id', item->>'product_id',
      'product_name', item->>'product_name',
      'product_image_url', COALESCE(p.image_url, item->>'product_image_url', ''),
      'quantity', GREATEST(COALESCE((item->>'quantity')::int, 1), 1),
      'last_price', COALESCE((item->>'price_per_unit')::numeric, 0),
      'current_price', CASE WHEN p.id IS NULL THEN NULL
        ELSE (floor(p.price * 1.125) + 0.99)::numeric END,
      'current_stock', COALESCE(p.stock, 0),
      'available', (p.id IS NOT NULL AND COALESCE(p.stock, 0) > 0),
      'selected_options', COALESCE(item->'selected_options', '[]'::jsonb)
    ) AS repriced
    FROM jsonb_array_elements(v_order.items) item
    LEFT JOIN public.products p
      ON p.id = NULLIF(item->>'product_id', '')::uuid
    WHERE jsonb_typeof(item) = 'object'
      AND NULLIF(COALESCE(item->>'product_id', ''), '') IS NOT NULL
      AND p.id IS NOT NULL
  ) r;

  IF v_items = '[]'::jsonb THEN
    RETURN;
  END IF;

  SELECT COALESCE(sum(
    COALESCE((item->>'current_price')::numeric, (item->>'last_price')::numeric, 0)
    * COALESCE((item->>'quantity')::int, 1)
  ), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(v_items) item
  WHERE (item->>'available')::boolean;

  RETURN QUERY
  SELECT
    v_order.id,
    v_order.order_number,
    v_order.store_id,
    s.name,
    s.image_url,
    s.is_open,
    v_order.total,
    v_subtotal,
    v_unavailable::integer,
    v_items
  FROM public.stores s
  WHERE s.id = v_order.store_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_usual_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_usual_order(uuid) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. RETENTION: configuration table, purge RPCs, stats helper.
-- ----------------------------------------------------------------------------

-- 2.1  Retention configuration (1 row, service role only).
CREATE TABLE IF NOT EXISTS public.qai_retention_policies (
    id boolean PRIMARY KEY DEFAULT TRUE CHECK (id = TRUE),
    conversations_days integer NOT NULL DEFAULT 90,
    messages_days integer NOT NULL DEFAULT 90,
    analytics_days integer NOT NULL DEFAULT 90,
    behaviour_days integer NOT NULL DEFAULT 365,
    quality_feedback_days integer NOT NULL DEFAULT 180,
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.qai_retention_policies ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.qai_retention_policies TO service_role;
GRANT UPDATE (conversations_days, messages_days, analytics_days, behaviour_days, quality_feedback_days, updated_at)
    ON public.qai_retention_policies TO service_role;

INSERT INTO public.qai_retention_policies (id)
VALUES (TRUE)
ON CONFLICT (id) DO NOTHING;

-- 2.2  Purge conversations / messages (hard delete; user can also soft-delete
--      via Flutter DELETE ai_conversations in-app).
CREATE OR REPLACE FUNCTION public.qai_purge_expired_conversations(p_limit integer DEFAULT 10000)
RETURNS TABLE(kind text, removed bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_cutoff_conv timestamptz;
    v_cutoff_msg  timestamptz;
    v_conv_days   integer;
    v_msg_days    integer;
    v_removed_msg bigint;
    v_removed_conv bigint;
BEGIN
    SELECT COALESCE(p.conversations_days, 90), COALESCE(p.messages_days, 90)
    INTO v_conv_days, v_msg_days
    FROM public.qai_retention_policies p LIMIT 1;
    v_cutoff_conv := now() - (v_conv_days || ' days')::interval;
    v_cutoff_msg  := now() - (v_msg_days  || ' days')::interval;

    -- Delete old messages first (FK references conversations).
    WITH dead AS (
        SELECT id FROM public.ai_messages
        WHERE created_at < v_cutoff_msg
        ORDER BY created_at ASC
        LIMIT p_limit
    )
    DELETE FROM public.ai_messages m USING dead d WHERE m.id = d.id;
    GET DIAGNOSTICS v_removed_msg = ROW_COUNT;

    -- Delete conversations that have no messages and are older than cutoff
    -- OR whose last update is older than cutoff_conv days.
    WITH dead AS (
        SELECT c.id
        FROM public.ai_conversations c
        LEFT JOIN public.ai_messages m ON m.conversation_id = c.id
        WHERE (c.updated_at IS NULL OR c.updated_at < v_cutoff_conv)
          AND (c.deleted_at IS NOT NULL OR c.updated_at < v_cutoff_conv)
        GROUP BY c.id
        HAVING count(m.id) = 0
        LIMIT p_limit
    )
    DELETE FROM public.ai_conversations c USING dead d WHERE c.id = d.id;
    GET DIAGNOSTICS v_removed_conv = ROW_COUNT;

    RETURN QUERY VALUES
        ('ai_messages',     v_removed_msg),
        ('ai_conversations', v_removed_conv);
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_purge_expired_conversations(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_purge_expired_conversations(integer) TO service_role;

-- 2.3  Purge analytics events (ai_query_events, ai_cart_events, ai_quality_feedback).
CREATE OR REPLACE FUNCTION public.qai_purge_expired_analytics(p_limit integer DEFAULT 50000)
RETURNS TABLE(kind text, removed bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_cutoff_an  timestamptz;
    v_cutoff_fb  timestamptz;
    v_an_days    integer;
    v_fb_days    integer;
    v_q bigint; v_c bigint; v_f bigint;
BEGIN
    SELECT COALESCE(p.analytics_days, 90), COALESCE(p.quality_feedback_days, 180)
    INTO v_an_days, v_fb_days
    FROM public.qai_retention_policies p LIMIT 1;
    v_cutoff_an := now() - (v_an_days || ' days')::interval;
    v_cutoff_fb := now() - (v_fb_days || ' days')::interval;

    WITH dead AS (SELECT id FROM public.ai_query_events WHERE created_at < v_cutoff_an ORDER BY created_at LIMIT p_limit)
    DELETE FROM public.ai_query_events t USING dead d WHERE t.id = d.id;
    GET DIAGNOSTICS v_q = ROW_COUNT;

    WITH dead AS (SELECT id FROM public.ai_cart_events  WHERE created_at < v_cutoff_an ORDER BY created_at LIMIT p_limit)
    DELETE FROM public.ai_cart_events  t USING dead d WHERE t.id = d.id;
    GET DIAGNOSTICS v_c = ROW_COUNT;

    WITH dead AS (SELECT id FROM public.ai_quality_feedback WHERE created_at < v_cutoff_fb ORDER BY created_at LIMIT (p_limit/5))
    DELETE FROM public.ai_quality_feedback t USING dead d WHERE t.id = d.id;
    GET DIAGNOSTICS v_f = ROW_COUNT;

    RETURN QUERY VALUES
        ('ai_query_events',    v_q),
        ('ai_cart_events',     v_c),
        ('ai_quality_feedback', v_f);
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_purge_expired_analytics(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_purge_expired_analytics(integer) TO service_role;

-- 2.4  Purge behavioural ai_events (Phase 2; longer retention).
CREATE OR REPLACE FUNCTION public.qai_purge_expired_events(p_limit integer DEFAULT 100000)
RETURNS TABLE(kind text, removed bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_cutoff  timestamptz;
    v_days    integer;
    v bigint;
BEGIN
    SELECT COALESCE(p.behaviour_days, 365) INTO v_days
    FROM public.qai_retention_policies p LIMIT 1;
    v_cutoff := now() - (v_days || ' days')::interval;

    WITH dead AS (SELECT id FROM public.ai_events WHERE created_at < v_cutoff ORDER BY created_at LIMIT p_limit)
    DELETE FROM public.ai_events t USING dead d WHERE t.id = d.id;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN QUERY VALUES ('ai_events', v);
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_purge_expired_events(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_purge_expired_events(integer) TO service_role;

-- ----------------------------------------------------------------------------
-- 3. ADMIN AUDIT LOGGING
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    action text NOT NULL,
    entity_type text,
    entity_id text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    ip text,
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON public.admin_audit_logs TO service_role;

CREATE INDEX IF NOT EXISTS admin_audit_logs_action_idx
    ON public.admin_audit_logs (action, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_audit_logs_entity_idx
    ON public.admin_audit_logs (entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_audit_logs_actor_idx
    ON public.admin_audit_logs (actor_user_id, created_at DESC);

COMMENT ON TABLE public.admin_audit_logs IS 'Phase 18 — admin-side tamper trail. Service role writes; never readable by anon/authenticated.';

-- 3.1  Logger RPC.
CREATE OR REPLACE FUNCTION public.qai_log_admin_action(
    p_action      text,
    p_entity_type text DEFAULT NULL,
    p_entity_id   text DEFAULT NULL,
    p_metadata    jsonb DEFAULT NULL,
    p_ip          text DEFAULT NULL,
    p_user_agent  text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO public.admin_audit_logs (
        actor_user_id, action, entity_type, entity_id, metadata, ip, user_agent
    ) VALUES (
        auth.uid(),
        p_action,
        p_entity_type,
        p_entity_id,
        COALESCE(p_metadata, '{}'::jsonb),
        p_ip,
        p_user_agent
    ) RETURNING id INTO v_id;
    RETURN v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_log_admin_action(text,text,text,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_log_admin_action(text,text,text,jsonb,text,text) TO service_role;

-- 3.2  Audit triggers on high-signal customer-side operations.
--      These fire AFTER the row change; exceptions → WARNING (never fail tx).

-- 3.2a ai_conversations DELETE → audit.
CREATE OR REPLACE FUNCTION public.qai_trg_audit_conversation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
    BEGIN
        INSERT INTO public.admin_audit_logs (action, entity_type, entity_id, actor_user_id, metadata)
        VALUES (
            CASE TG_OP WHEN 'DELETE' THEN 'ai_conversation_deleted'
                       WHEN 'UPDATE' THEN 'ai_conversation_updated'
                       ELSE 'ai_conversation_inserted' END,
            'ai_conversation',
            COALESCE(OLD.id, NEW.id)::text,
            COALESCE(OLD.user_id, NEW.user_id),
            jsonb_build_object('tg_op', TG_OP, 'title', COALESCE(NEW.title, OLD.title))
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'qai_trg_audit_conversation failed: %', SQLERRM;
    END;
    RETURN COALESCE(NEW, OLD);
END;
$fn$;
DROP TRIGGER IF EXISTS qai_audit_conversation_trg ON public.ai_conversations;
CREATE TRIGGER qai_audit_conversation_trg
AFTER INSERT OR UPDATE OR DELETE ON public.ai_conversations
FOR EACH ROW EXECUTE FUNCTION public.qai_trg_audit_conversation();

-- 3.2b customer_ai_profiles UPDATE/DELETE → audit.
CREATE OR REPLACE FUNCTION public.qai_trg_audit_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
    BEGIN
        INSERT INTO public.admin_audit_logs (action, entity_type, entity_id, actor_user_id, metadata)
        VALUES (
            CASE TG_OP WHEN 'DELETE' THEN 'profile_deleted'
                       WHEN 'UPDATE' THEN 'profile_updated'
                       ELSE 'profile_inserted' END,
            'customer_ai_profile',
            COALESCE(OLD.user_id, NEW.user_id)::text,
            COALESCE(OLD.user_id, NEW.user_id),
            jsonb_build_object('tg_op', TG_OP)
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'qai_trg_audit_profile failed: %', SQLERRM;
    END;
    RETURN COALESCE(NEW, OLD);
END;
$fn$;
DROP TRIGGER IF EXISTS qai_audit_profile_trg ON public.customer_ai_profiles;
CREATE TRIGGER qai_audit_profile_trg
AFTER INSERT OR UPDATE OR DELETE ON public.customer_ai_profiles
FOR EACH ROW EXECUTE FUNCTION public.qai_trg_audit_profile();

-- ----------------------------------------------------------------------------
-- 4. FINAL: Sanity-check summary (inline tests pass if migration ran idempotent).
--    SELECT count(*) FROM public.qai_retention_policies → 1.
--    SELECT proname FROM pg_proc WHERE proname LIKE 'qai_purge_%' OR proname = 'qai_log_admin_action' → 5 rows.
--    SELECT tgname FROM pg_trigger WHERE tgname LIKE 'qai_audit_%' → 2 rows.
--    SELECT relname FROM pg_class WHERE relname = 'admin_audit_logs' → present.
-- ============================================================================
