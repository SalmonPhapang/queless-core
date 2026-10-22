-- 20260922_qai_affinity.sql
--
-- Q AI Phase 3 — Customer Affinity Engine (queless_ai_roadmap.md §7).
--
-- Three per-customer affinity tables fed by two paths:
--   1. behaviour events   (ai_events rows inserted by the app/edge)
--   2. completed orders   (orders reaching the terminal 'delivered' state)
--
-- Design constraints learned in this codebase:
--   * No trigger on customer-critical tables may ever fail a customer's
--     write (see the alerts RLS incident). Both triggers here are
--     SECURITY DEFINER with BEGIN/EXCEPTION guards: a failure can only
--     produce a WARNING, never an aborted order.
--   * Affinity rows are derivable state, not source of truth: they are
--     recomputed from ai_events + delivered orders, so any backfill or
--     re-weighting is just a re-run, not a data migration.
--
-- Scoring weights (roadmap §7):
--   order +10 | add_to_cart +6 | recommendation_clicked +4
--   view +2   | search +2       | dismissed -2
--   Recency: geometric half-life of 21 days. score = SUM(w * 0.5^(age_days/21)).

BEGIN;

-- ============================================================
-- Affinity tables
-- ============================================================

CREATE TABLE IF NOT EXISTS public.customer_product_affinity (
  user_id           uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  product_id        uuid NOT NULL REFERENCES public.products (id) ON DELETE CASCADE,
  purchase_count    integer NOT NULL DEFAULT 0,
  view_count        integer NOT NULL DEFAULT 0,
  search_count      integer NOT NULL DEFAULT 0,
  cart_add_count    integer NOT NULL DEFAULT 0,
  last_purchased_at timestamptz,
  affinity_score    numeric NOT NULL DEFAULT 0,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS cpa_user_score_idx
  ON public.customer_product_affinity (user_id, affinity_score DESC);
CREATE INDEX IF NOT EXISTS cpa_product_idx
  ON public.customer_product_affinity (product_id);

CREATE TABLE IF NOT EXISTS public.customer_store_affinity (
  user_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  store_id           uuid NOT NULL REFERENCES public.stores (id) ON DELETE CASCADE,
  order_count        integer NOT NULL DEFAULT 0,
  view_count         integer NOT NULL DEFAULT 0,
  last_ordered_at    timestamptz,
  average_order_value numeric,
  affinity_score     numeric NOT NULL DEFAULT 0,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, store_id)
);

CREATE INDEX IF NOT EXISTS csa_user_score_idx
  ON public.customer_store_affinity (user_id, affinity_score DESC);

CREATE TABLE IF NOT EXISTS public.customer_cuisine_affinity (
  user_id             uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  cuisine             text NOT NULL,
  interaction_count   integer NOT NULL DEFAULT 0,
  order_count         integer NOT NULL DEFAULT 0,
  score               numeric NOT NULL DEFAULT 0,
  last_interaction_at timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, cuisine)
);

CREATE INDEX IF NOT EXISTS cca_user_score_idx
  ON public.customer_cuisine_affinity (user_id, score DESC);

-- Owner-only access. The SECURITY DEFINER triggers bypass RLS legitimately
-- (owned by the table owner); customers can read their own affinities.
ALTER TABLE public.customer_product_affinity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_store_affinity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_cuisine_affinity ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cpa_select_own" ON public.customer_product_affinity;
CREATE POLICY "cpa_select_own" ON public.customer_product_affinity
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS "csa_select_own" ON public.customer_store_affinity;
CREATE POLICY "csa_select_own" ON public.customer_store_affinity
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS "cca_select_own" ON public.customer_cuisine_affinity;
CREATE POLICY "cca_select_own" ON public.customer_cuisine_affinity
  FOR SELECT TO authenticated USING (user_id = auth.uid());
-- No INSERT/UPDATE/DELETE policies: only the definer triggers write here.

-- ============================================================
-- Scoring core
-- ============================================================

-- NOTE (hardened 2026-09-22, later in this same file): entity_id for
-- product_searched events is a free-text search term, not a uuid. The product
-- branch below therefore casts through a regex guard instead of a bare
-- entity_id::uuid, which would abort the whole rebuild on the first search
-- event. If applying this file in one shot elsewhere, apply it and then the
-- hardened replacement at the bottom of the file.

CREATE OR REPLACE FUNCTION public.qai_affinity_weight(p_event_type text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE p_event_type
    WHEN 'order_completed' THEN 10
    WHEN 'product_added' THEN 6
    WHEN 'recommendation_clicked' THEN 4
    WHEN 'product_viewed' THEN 2
    WHEN 'store_viewed' THEN 2
    WHEN 'recipe_viewed' THEN 2
    WHEN 'product_searched' THEN 2
    WHEN 'recommendation_dismissed' THEN -2
    ELSE 0
  END;
$fn$;

-- Recency weight: geometric decay, 21-day half-life. Today = 1.0,
-- 21 days ago = 0.5, 42 days ago = 0.25. Nothing older than 90 days counts.
CREATE OR REPLACE FUNCTION public.qai_recency_weight(p_at timestamptz)
RETURNS numeric LANGUAGE sql STABLE AS $fn$
  SELECT GREATEST(0, power(0.5, GREATEST(0, EXTRACT(EPOCH FROM (now() - p_at)) / 86400.0) / 21.0))::numeric
$fn$;

-- ============================================================
-- Rebuild one customer's affinities from source data.
-- Idempotent: DELETE + INSERT inside the caller's transaction.
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_rebuild_affinities(p_user_id uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  -- ---- product affinity: events + delivered order items -------------------
  DELETE FROM public.customer_product_affinity WHERE user_id = p_user_id;

  INSERT INTO public.customer_product_affinity
    (user_id, product_id, affinity_score, view_count, search_count,
     cart_add_count, purchase_count, last_purchased_at)
  SELECT
    p_user_id,
    entity_id::uuid AS product_id,
    SUM(w * rec) AS affinity_score,
    SUM(view_cnt)::integer,
    SUM(search_cnt)::integer,
    SUM(cart_cnt)::integer,
    SUM(purch_cnt)::integer,
    MAX(last_purch)
  FROM (
    -- behavioural events (view/search/cart/click/dismiss)
    SELECT
      e.entity_id::uuid AS product_id,
      public.qai_affinity_weight(e.event_type) AS w,
      public.qai_recency_weight(e.created_at) AS rec,
      CASE WHEN e.event_type = 'product_viewed' THEN 1 ELSE 0 END AS view_cnt,
      CASE WHEN e.event_type = 'product_searched' THEN 1 ELSE 0 END AS search_cnt,
      CASE WHEN e.event_type = 'product_added' THEN 1 ELSE 0 END AS cart_cnt,
      0::integer AS purch_cnt,
      NULL::timestamptz AS last_purch
    FROM public.ai_events e
    WHERE e.user_id = p_user_id
      AND e.entity_type = 'product'
      AND e.entity_id IS NOT NULL
      AND e.entity_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND e.created_at > now() - interval '90 days'
    UNION ALL
    -- delivered order items
    SELECT
      (item->>'product_id')::uuid,
      10::numeric,
      public.qai_recency_weight(o.updated_at),
      0, 0, 0,
      LEAST((item->>'quantity')::int, 99),
      o.updated_at
    FROM public.orders o
    CROSS JOIN LATERAL jsonb_array_elements(o.items) AS item
    WHERE o.user_id = p_user_id
      AND o.status = 'delivered'
      AND jsonb_typeof(o.items) = 'array'
      AND COALESCE(item->>'product_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) src
  WHERE product_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.products pr WHERE pr.id = product_id)
  GROUP BY product_id
  ON CONFLICT (user_id, product_id) DO UPDATE
    SET affinity_score = EXCLUDED.affinity_score,
        view_count = EXCLUDED.view_count,
        search_count = EXCLUDED.search_count,
        cart_add_count = EXCLUDED.cart_add_count,
        purchase_count = EXCLUDED.purchase_count,
        last_purchased_at = EXCLUDED.last_purchased_at;

  -- ---- store affinity: events + delivered orders --------------------------
  DELETE FROM public.customer_store_affinity WHERE user_id = p_user_id;

  INSERT INTO public.customer_store_affinity
    (user_id, store_id, affinity_score, view_count, order_count,
     last_ordered_at, average_order_value)
  SELECT
    p_user_id,
    src.store_id,
    SUM(src.w * src.rec) AS affinity_score,
    SUM(src.view_cnt)::integer,
    SUM(src.order_cnt)::integer,
    MAX(src.last_order),
    -- AOV over delivered orders only; NULL when none.
    CASE WHEN SUM(src.order_cnt) > 0
         THEN ROUND(SUM(src.order_total) / SUM(src.order_cnt), 2)
         ELSE NULL END
  FROM (
    SELECT
      o.store_id,
      public.qai_affinity_weight('order_completed') AS w,
      public.qai_recency_weight(o.updated_at) AS rec,
      0::integer AS view_cnt,
      1::integer AS order_cnt,
      o.total::numeric AS order_total,
      o.updated_at AS last_order
    FROM public.orders o
    WHERE o.user_id = p_user_id AND o.status = 'delivered' AND o.store_id IS NOT NULL
    UNION ALL
    SELECT
      e.entity_id::uuid,
      public.qai_affinity_weight('store_viewed') AS w,
      public.qai_recency_weight(e.created_at) AS rec,
      1::integer,
      0::integer,
      NULL::numeric,
      NULL::timestamptz
    FROM public.ai_events e
    WHERE e.user_id = p_user_id
      AND e.entity_type = 'store'
      AND e.entity_id IS NOT NULL
      AND e.entity_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND e.created_at > now() - interval '90 days'
  ) src
  WHERE src.store_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.stores st WHERE st.id = src.store_id)
  GROUP BY src.store_id
  ON CONFLICT (user_id, store_id) DO UPDATE
    SET affinity_score = EXCLUDED.affinity_score,
        view_count = EXCLUDED.view_count,
        order_count = EXCLUDED.order_count,
        last_ordered_at = EXCLUDED.last_ordered_at,
        average_order_value = EXCLUDED.average_order_value;

  -- ---- cuisine affinity: events with metadata.cuisine + orders via store --
  DELETE FROM public.customer_cuisine_affinity WHERE user_id = p_user_id;

  INSERT INTO public.customer_cuisine_affinity
    (user_id, cuisine, score, interaction_count, order_count, last_interaction_at)
  SELECT
    p_user_id,
    src.cuisine,
    SUM(src.w * src.rec) AS score,
    SUM(src.cnt)::integer,
    SUM(src.order_cnt)::integer,
    MAX(src.last_at)
  FROM (
    SELECT
      LOWER(TRIM(e.metadata->>'cuisine')) AS cuisine,
      public.qai_affinity_weight(e.event_type) AS w,
      public.qai_recency_weight(e.created_at) AS rec,
      1::integer AS cnt,
      0::integer AS order_cnt,
      e.created_at AS last_at
    FROM public.ai_events e
    WHERE e.user_id = p_user_id
      AND e.metadata->>'cuisine' IS NOT NULL
      AND e.created_at > now() - interval '90 days'
    UNION ALL
    SELECT
      LOWER(TRIM(s.category)),
      10::numeric,
      public.qai_recency_weight(o.updated_at),
      1::integer,
      1::integer,
      o.updated_at
    FROM public.orders o
    JOIN public.stores s ON s.id = o.store_id
    WHERE o.user_id = p_user_id AND o.status = 'delivered'
      AND COALESCE(s.category, '') <> ''
  ) src
  WHERE src.cuisine IS NOT NULL AND src.cuisine <> ''
  GROUP BY src.cuisine
  ON CONFLICT (user_id, cuisine) DO UPDATE
    SET score = EXCLUDED.score,
        interaction_count = EXCLUDED.interaction_count,
        order_count = EXCLUDED.order_count,
        last_interaction_at = EXCLUDED.last_interaction_at;
END $fn$;

-- ============================================================
-- Profile refresh — folds affinities into customer_ai_profiles.
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_refresh_profile(p_user_id uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_orders integer;
  v_aov numeric;
  v_last_order timestamptz;
  v_fav_store uuid;
  v_pref_day smallint;
  v_pref_hour smallint;
  v_cuisines text[];
  v_categories text[];
BEGIN
  SELECT COUNT(*), AVG(o.total), MAX(o.updated_at)
    INTO v_orders, v_aov, v_last_order
  FROM public.orders o
  WHERE o.user_id = p_user_id AND o.status = 'delivered';

  SELECT store_id INTO v_fav_store
  FROM public.customer_store_affinity
  WHERE user_id = p_user_id AND order_count > 0
  ORDER BY affinity_score DESC
  LIMIT 1;

  SELECT EXTRACT(DOW FROM o.updated_at)::smallint, EXTRACT(HOUR FROM o.updated_at)::smallint
    INTO v_pref_day, v_pref_hour
  FROM public.orders o
  WHERE o.user_id = p_user_id AND o.status = 'delivered'
  GROUP BY EXTRACT(DOW FROM o.updated_at), EXTRACT(HOUR FROM o.updated_at)
  ORDER BY COUNT(*) DESC
  LIMIT 1;

  SELECT ARRAY(
    SELECT cuisine FROM public.customer_cuisine_affinity
    WHERE user_id = p_user_id
    ORDER BY score DESC LIMIT 5
  ) INTO v_cuisines;

  -- Favourite categories from the highest-affinity products.
  SELECT ARRAY(
    SELECT DISTINCT p.category
    FROM public.customer_product_affinity cpa
    JOIN public.products p ON p.id = cpa.product_id
    WHERE cpa.user_id = p_user_id
    ORDER BY p.category
    LIMIT 5
  ) INTO v_categories;

  INSERT INTO public.customer_ai_profiles
    (user_id, total_orders, average_order_value, last_order_at,
     favourite_store_id, preferred_order_day, preferred_order_hour,
     favourite_cuisines, favourite_categories)
  VALUES
    (p_user_id, v_orders, v_aov, v_last_order,
     v_fav_store, v_pref_day, v_pref_hour,
     COALESCE(v_cuisines, '{}'), COALESCE(v_categories, '{}'))
  ON CONFLICT (user_id) DO UPDATE
    SET total_orders = EXCLUDED.total_orders,
        average_order_value = EXCLUDED.average_order_value,
        last_order_at = EXCLUDED.last_order_at,
        favourite_store_id = EXCLUDED.favourite_store_id,
        preferred_order_day = EXCLUDED.preferred_order_day,
        preferred_order_hour = EXCLUDED.preferred_order_hour,
        favourite_cuisines = EXCLUDED.favourite_cuisines,
        favourite_categories = EXCLUDED.favourite_categories,
        updated_at = now();
END $fn$;

-- Combined entry point: rebuild affinities, then fold into the profile.
CREATE OR REPLACE FUNCTION public.qai_refresh_customer_ai(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  PERFORM public.qai_rebuild_affinities(p_user_id);
  PERFORM public.qai_refresh_profile(p_user_id);
END $fn$;

REVOKE ALL ON FUNCTION public.qai_refresh_customer_ai(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qai_refresh_customer_ai(uuid) TO authenticated, service_role;

-- ============================================================
-- Triggers — SECURITY DEFINER + guarded: internal side effects must never
-- fail a customer's write (the alerts incident).
-- ============================================================

-- 1) behaviour event -> debounced rebuild
CREATE OR REPLACE FUNCTION public.qai_on_ai_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_target uuid;
BEGIN
  v_target := NEW.user_id;

  -- Debounce: at most one rebuild per user per 5 minutes. The enqueue row
  -- is deleted by the rebuild; PK conflict means one is already queued/done.
  INSERT INTO public.qai_affinity_jobs (user_id, enqueued_at)
  VALUES (v_target, now())
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'qai_on_ai_event failed for user %: %', v_target, SQLERRM;
  RETURN NEW;
END $fn$;

-- 2) order delivered -> rebuild (purchase signal, weight 10)
CREATE OR REPLACE FUNCTION public.qai_on_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.status = 'delivered' AND COALESCE(OLD.status, '') <> 'delivered' THEN
    INSERT INTO public.qai_affinity_jobs (user_id, enqueued_at)
    VALUES (NEW.user_id, now())
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'qai_on_order_status failed for order %: %', NEW.id, SQLERRM;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_qai_on_ai_event ON public.ai_events;
CREATE TRIGGER trg_qai_on_ai_event
  AFTER INSERT ON public.ai_events
  FOR EACH ROW EXECUTE FUNCTION public.qai_on_ai_event();

DROP TRIGGER IF EXISTS trg_qai_on_order_status ON public.orders;
CREATE TRIGGER trg_qai_on_order_status
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.qai_on_order_status();

-- ============================================================
-- Job queue: the debounce table + processor. Rebuilds run here, not in the
-- trigger, so a burst of events costs one rebuild per 5-minute window.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.qai_affinity_jobs (
  user_id     uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  enqueued_at timestamptz NOT NULL DEFAULT now()
);

-- pg_cron: process the queue every 5 minutes (batch max 200 users/run).
-- Safe to re-run: drops+recreates the same job name.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('qai-affinity-refresh');
    PERFORM cron.schedule(
      'qai-affinity-refresh',
      '*/5 * * * *',
      $job$
      WITH ready AS (
        SELECT user_id FROM public.qai_affinity_jobs
        WHERE enqueued_at < now() - interval '5 minutes'
        LIMIT 200
      ), done AS (
        DELETE FROM public.qai_affinity_jobs j USING ready r
        WHERE j.user_id = r.user_id RETURNING j.user_id
      )
      SELECT public.qai_refresh_customer_ai(user_id) FROM done
      $job$
    );
  ELSE
    RAISE NOTICE 'pg_cron not installed: qai_affinity_jobs will be processed by the qai_refresh_customer_ai RPC instead';
  END IF;
END $$;

-- Fallback for callers without pg_cron: expose the same batch step.
CREATE OR REPLACE FUNCTION public.qai_process_affinity_jobs(p_batch_size integer DEFAULT 200)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_count integer := 0;
  v_ids uuid[];
  r record;
BEGIN
  -- Capture the ready user_ids AND dequeue them atomically, BEFORE processing.
  -- (Fixed 2026-09-23: the original re-queried the table in the loop AFTER the
  -- CTE had deleted the jobs, so the refresh never ran. A rolled-back replay
  -- proved it: job deleted, 0 affinities built.)
  WITH ready AS (
    SELECT user_id FROM public.qai_affinity_jobs
    WHERE enqueued_at < now() - interval '5 minutes'
    LIMIT GREATEST(p_batch_size, 1)
  ), done AS (
    DELETE FROM public.qai_affinity_jobs j USING ready r
    WHERE j.user_id = r.user_id
    RETURNING j.user_id
  )
  SELECT array_agg(user_id) INTO v_ids FROM done;

  v_count := coalesce(array_length(v_ids, 1), 0);

  FOR r IN SELECT unnest(v_ids) AS user_id LOOP
    BEGIN
      PERFORM public.qai_refresh_customer_ai(r.user_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'qai_refresh_customer_ai failed for %: %', r.user_id, SQLERRM;
    END;
  END LOOP;
  RETURN v_count;
END $fn$;

COMMIT;

-- ============================================================
-- uuid-regex-guard (hardened 2026-09-22): product_searched stores a free-text
-- term in entity_id; a bare entity_id::uuid aborts the rebuild. Re-run this
-- replacement after the file above if applying by hand. Already applied live.
-- ============================================================
CREATE OR REPLACE FUNCTION public.qai_rebuild_affinities(p_user_id uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  DELETE FROM public.customer_product_affinity WHERE user_id = p_user_id;
  INSERT INTO public.customer_product_affinity
    (user_id, product_id, affinity_score, view_count, search_count, cart_add_count, purchase_count, last_purchased_at)
  SELECT p_user_id, src.product_id, SUM(src.w * src.rec),
         SUM(src.view_cnt)::integer, SUM(src.search_cnt)::integer,
         SUM(src.cart_cnt)::integer, SUM(src.purch_cnt)::integer, MAX(src.last_purch)
  FROM (
    SELECT CASE WHEN e.entity_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN e.entity_id::uuid END AS product_id,
           public.qai_affinity_weight(e.event_type) AS w,
           public.qai_recency_weight(e.created_at) AS rec,
           CASE WHEN e.event_type = 'product_viewed' THEN 1 ELSE 0 END AS view_cnt,
           CASE WHEN e.event_type = 'product_searched' THEN 1 ELSE 0 END AS search_cnt,
           CASE WHEN e.event_type = 'product_added' THEN 1 ELSE 0 END AS cart_cnt,
           0::integer AS purch_cnt, NULL::timestamptz AS last_purch
    FROM public.ai_events e
    WHERE e.user_id = p_user_id AND e.entity_type = 'product'
      AND e.entity_id IS NOT NULL AND e.created_at > now() - interval '90 days'
    UNION ALL
    SELECT (item->>'product_id')::uuid, 10::numeric,
           public.qai_recency_weight(o.updated_at), 0, 0, 0,
           LEAST((item->>'quantity')::int, 99), o.updated_at
    FROM public.orders o
    CROSS JOIN LATERAL jsonb_array_elements(o.items) AS item
    WHERE o.user_id = p_user_id AND o.status = 'delivered'
      AND jsonb_typeof(o.items) = 'array' AND COALESCE(item->>'product_id', '') <> ''
  ) src
  WHERE src.product_id IS NOT NULL
  GROUP BY src.product_id
  ON CONFLICT (user_id, product_id) DO UPDATE
    SET affinity_score = EXCLUDED.affinity_score, view_count = EXCLUDED.view_count,
        search_count = EXCLUDED.search_count, cart_add_count = EXCLUDED.cart_add_count,
        purchase_count = EXCLUDED.purchase_count, last_purchased_at = EXCLUDED.last_purchased_at;

  DELETE FROM public.customer_store_affinity WHERE user_id = p_user_id;
  INSERT INTO public.customer_store_affinity
    (user_id, store_id, affinity_score, view_count, order_count, last_ordered_at, average_order_value)
  SELECT p_user_id, src.store_id, SUM(src.w * src.rec),
         SUM(src.view_cnt)::integer, SUM(src.order_cnt)::integer,
         MAX(src.last_order),
         CASE WHEN SUM(src.order_cnt) > 0 THEN ROUND(SUM(src.order_total) / SUM(src.order_cnt), 2) ELSE NULL END
  FROM (
    SELECT o.store_id, 10::numeric AS w, public.qai_recency_weight(o.updated_at) AS rec,
           0::integer AS view_cnt, 1::integer AS order_cnt,
           o.total::numeric AS order_total, o.updated_at AS last_order
    FROM public.orders o
    WHERE o.user_id = p_user_id AND o.status = 'delivered' AND o.store_id IS NOT NULL
    UNION ALL
    SELECT CASE WHEN e.entity_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN e.entity_id::uuid END,
           2::numeric, public.qai_recency_weight(e.created_at),
           1::integer, 0::integer, NULL::numeric, NULL::timestamptz
    FROM public.ai_events e
    WHERE e.user_id = p_user_id AND e.entity_type = 'store'
      AND e.entity_id IS NOT NULL AND e.created_at > now() - interval '90 days'
  ) src
  WHERE src.store_id IS NOT NULL
  GROUP BY src.store_id
  ON CONFLICT (user_id, store_id) DO UPDATE
    SET affinity_score = EXCLUDED.affinity_score, view_count = EXCLUDED.view_count,
        order_count = EXCLUDED.order_count, last_ordered_at = EXCLUDED.last_ordered_at,
        average_order_value = EXCLUDED.average_order_value;

  DELETE FROM public.customer_cuisine_affinity WHERE user_id = p_user_id;
  INSERT INTO public.customer_cuisine_affinity
    (user_id, cuisine, score, interaction_count, order_count, last_interaction_at)
  SELECT p_user_id, src.cuisine, SUM(src.w * src.rec),
         SUM(src.cnt)::integer, SUM(src.order_cnt)::integer, MAX(src.last_at)
  FROM (
    SELECT LOWER(TRIM(e.metadata->>'cuisine')) AS cuisine,
           public.qai_affinity_weight(e.event_type) AS w,
           public.qai_recency_weight(e.created_at) AS rec,
           1::integer AS cnt, 0::integer AS order_cnt, e.created_at AS last_at
    FROM public.ai_events e
    WHERE e.user_id = p_user_id AND e.metadata->>'cuisine' IS NOT NULL
      AND e.created_at > now() - interval '90 days'
    UNION ALL
    SELECT LOWER(TRIM(s.category)), 10::numeric,
           public.qai_recency_weight(o.updated_at), 1::integer, 1::integer, o.updated_at
    FROM public.orders o
    JOIN public.stores s ON s.id = o.store_id
    WHERE o.user_id = p_user_id AND o.status = 'delivered' AND COALESCE(s.category, '') <> ''
  ) src
  WHERE src.cuisine IS NOT NULL AND src.cuisine <> ''
  GROUP BY src.cuisine
  ON CONFLICT (user_id, cuisine) DO UPDATE
    SET score = EXCLUDED.score, interaction_count = EXCLUDED.interaction_count,
        order_count = EXCLUDED.order_count, last_interaction_at = EXCLUDED.last_interaction_at;
END $fn$;

-- ============================================================
-- Verification (run after applying):
--   SELECT public.qai_refresh_customer_ai('<user-uuid>');
--   SELECT * FROM public.customer_store_affinity WHERE user_id = '<user-uuid>';
--   SELECT * FROM public.customer_ai_profiles WHERE user_id = '<user-uuid>';
-- ============================================================
