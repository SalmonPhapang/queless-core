-- 20260922_qai_foundation.sql
--
-- Q AI foundation (roadmap Phases 1, 2, 4, 5, 10):
--   pgvector, ai_events (behaviour), customer_ai_profiles,
--   product_ai_metadata / store_ai_metadata, recipes (+ product matches),
--   ai_conversations / ai_messages.
--
-- Principles (queless_ai_roadmap.md):
--   * The LLM handles language; Supabase holds the truth.
--   * All customer-specific tables are RLS-protected, owner-only.
--   * Catalog tables (products/stores/recipes + metadata) are readable by
--     authenticated customers; writes happen only via service role.
--   * No triggers on customer-critical tables (see the alerts lesson: an
--     internal side effect must never fail a customer's write).
--
-- Embedding dimension: 768 (matches nomic-embed-text v1.5 and Gemini
-- text-embedding-004). The embedding pipeline (Phase 6) is a later
-- increment; columns exist now so search can light up without another
-- column migration.

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- Phase 2 — Behavioural events (append-only for customers)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.ai_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN (
                'product_viewed', 'product_searched', 'store_viewed',
                'recipe_viewed', 'recipe_ingredient_clicked',
                'recommendation_shown', 'recommendation_clicked',
                'recommendation_dismissed', 'cart_created',
                'product_added', 'order_completed', 'order_again_clicked',
                'ai_query')),
  entity_type text,
  entity_id   text,
  metadata    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_events_user_created_idx
  ON public.ai_events (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_events_type_idx
  ON public.ai_events (event_type, created_at DESC);

ALTER TABLE public.ai_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ai_events_insert_own" ON public.ai_events;
CREATE POLICY "ai_events_insert_own" ON public.ai_events
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "ai_events_select_own" ON public.ai_events;
CREATE POLICY "ai_events_select_own" ON public.ai_events
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());
-- No UPDATE/DELETE policies: the event log is append-only to customers.

-- ============================================================
-- Phase 1 — Customer AI profile
-- ============================================================

CREATE TABLE IF NOT EXISTS public.customer_ai_profiles (
  user_id              uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  average_order_value  numeric,
  total_orders         integer NOT NULL DEFAULT 0,
  favourite_store_id   uuid,
  preferred_order_day  smallint CHECK (preferred_order_day BETWEEN 0 AND 6),
  preferred_order_hour smallint CHECK (preferred_order_hour BETWEEN 0 AND 23),
  favourite_cuisines   text[] NOT NULL DEFAULT '{}',
  favourite_categories text[] NOT NULL DEFAULT '{}',
  dietary_preferences  text[] NOT NULL DEFAULT '{}',
  common_searches      text[] NOT NULL DEFAULT '{}',
  preferred_price_range numeric[],
  last_order_at        timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.customer_ai_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "customer_ai_profiles_select_own" ON public.customer_ai_profiles;
CREATE POLICY "customer_ai_profiles_select_own" ON public.customer_ai_profiles
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS "customer_ai_profiles_insert_own" ON public.customer_ai_profiles;
CREATE POLICY "customer_ai_profiles_insert_own" ON public.customer_ai_profiles
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "customer_ai_profiles_update_own" ON public.customer_ai_profiles;
CREATE POLICY "customer_ai_profiles_update_own" ON public.customer_ai_profiles
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- ============================================================
-- Phase 4 — Product / Store AI metadata
-- ============================================================

CREATE TABLE IF NOT EXISTS public.product_ai_metadata (
  product_id      uuid PRIMARY KEY REFERENCES public.products (id) ON DELETE CASCADE,
  cuisine_tags    text[] NOT NULL DEFAULT '{}',
  dietary_tags    text[] NOT NULL DEFAULT '{}',
  ingredient_tags text[] NOT NULL DEFAULT '{}',
  meal_types      text[] NOT NULL DEFAULT '{}',
  flavour_tags    text[] NOT NULL DEFAULT '{}',
  halal_status    text NOT NULL DEFAULT 'unknown'
                  CHECK (halal_status IN ('unknown', 'not_halal', 'halal', 'certified_halal')),
  vegetarian      boolean,
  vegan           boolean,
  spicy_level     smallint CHECK (spicy_level BETWEEN 0 AND 3),
  ai_description  text,
  searchable_text text,
  embedding       vector(768),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.product_ai_metadata ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "product_ai_metadata_read" ON public.product_ai_metadata;
CREATE POLICY "product_ai_metadata_read" ON public.product_ai_metadata
  FOR SELECT TO authenticated USING (true);

CREATE TABLE IF NOT EXISTS public.store_ai_metadata (
  store_id        uuid PRIMARY KEY REFERENCES public.stores (id) ON DELETE CASCADE,
  cuisine_tags    text[] NOT NULL DEFAULT '{}',
  dietary_tags    text[] NOT NULL DEFAULT '{}',
  speciality_tags text[] NOT NULL DEFAULT '{}',
  searchable_text text,
  embedding       vector(768),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_ai_metadata ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "store_ai_metadata_read" ON public.store_ai_metadata;
CREATE POLICY "store_ai_metadata_read" ON public.store_ai_metadata
  FOR SELECT TO authenticated USING (true);

-- ============================================================
-- Phase 5 — Recipes
-- ============================================================

CREATE TABLE IF NOT EXISTS public.recipes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title          text NOT NULL,
  description    text NOT NULL DEFAULT '',
  cuisine        text,
  dietary_tags   text[] NOT NULL DEFAULT '{}',
  meal_type      text,
  difficulty     text,
  prep_minutes   integer,
  cook_minutes   integer,
  servings       integer NOT NULL DEFAULT 2,
  ingredients    jsonb NOT NULL DEFAULT '[]',  -- [{name, quantity, optional}]
  instructions   jsonb NOT NULL DEFAULT '[]',  -- [string, ...]
  source         text NOT NULL DEFAULT 'seeded'
                 CHECK (source IN ('seeded', 'ai_generated', 'merchant')),
  searchable_text text,
  embedding      vector(768),
  created_at     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "recipes_read" ON public.recipes;
CREATE POLICY "recipes_read" ON public.recipes
  FOR SELECT TO authenticated USING (true);

CREATE TABLE IF NOT EXISTS public.recipe_product_matches (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id      uuid NOT NULL REFERENCES public.recipes (id) ON DELETE CASCADE,
  product_id     uuid NOT NULL REFERENCES public.products (id) ON DELETE CASCADE,
  ingredient_name text NOT NULL,
  match_score    numeric NOT NULL DEFAULT 0.5,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recipe_id, product_id, ingredient_name)
);

ALTER TABLE public.recipe_product_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "recipe_product_matches_read" ON public.recipe_product_matches;
CREATE POLICY "recipe_product_matches_read" ON public.recipe_product_matches
  FOR SELECT TO authenticated USING (true);

-- ============================================================
-- Phase 10 — Conversations
-- ============================================================

CREATE TABLE IF NOT EXISTS public.ai_conversations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  title      text NOT NULL DEFAULT 'New chat',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_conversations_user_idx
  ON public.ai_conversations (user_id, updated_at DESC);

ALTER TABLE public.ai_conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ai_conversations_select_own" ON public.ai_conversations;
CREATE POLICY "ai_conversations_select_own" ON public.ai_conversations
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS "ai_conversations_insert_own" ON public.ai_conversations;
CREATE POLICY "ai_conversations_insert_own" ON public.ai_conversations
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "ai_conversations_update_own" ON public.ai_conversations;
CREATE POLICY "ai_conversations_update_own" ON public.ai_conversations
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS "ai_conversations_delete_own" ON public.ai_conversations;
CREATE POLICY "ai_conversations_delete_own" ON public.ai_conversations
  FOR DELETE TO authenticated USING (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS public.ai_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.ai_conversations (id) ON DELETE CASCADE,
  role            text NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system')),
  content         text NOT NULL DEFAULT '',
  tool_name       text,
  tool_arguments  jsonb,
  tool_result     jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_messages_conversation_idx
  ON public.ai_messages (conversation_id, created_at);

ALTER TABLE public.ai_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ai_messages_select_own" ON public.ai_messages;
CREATE POLICY "ai_messages_select_own" ON public.ai_messages
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.ai_conversations c
     WHERE c.id = ai_messages.conversation_id AND c.user_id = auth.uid()));

DROP POLICY IF EXISTS "ai_messages_insert_own" ON public.ai_messages;
CREATE POLICY "ai_messages_insert_own" ON public.ai_messages
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.ai_conversations c
     WHERE c.id = ai_messages.conversation_id AND c.user_id = auth.uid()));
-- The edge function writes messages via the service role, so these policies
-- only gate direct client access.

-- ============================================================
-- updated_at touch triggers (catalog tables only — never orders)
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_qai_product_meta_touch ON public.product_ai_metadata;
CREATE TRIGGER trg_qai_product_meta_touch
  BEFORE UPDATE ON public.product_ai_metadata
  FOR EACH ROW EXECUTE FUNCTION public.qai_touch_updated_at();

DROP TRIGGER IF EXISTS trg_qai_store_meta_touch ON public.store_ai_metadata;
CREATE TRIGGER trg_qai_store_meta_touch
  BEFORE UPDATE ON public.store_ai_metadata
  FOR EACH ROW EXECUTE FUNCTION public.qai_touch_updated_at();

DROP TRIGGER IF EXISTS trg_qai_profile_touch ON public.customer_ai_profiles;
CREATE TRIGGER trg_qai_profile_touch
  BEFORE UPDATE ON public.customer_ai_profiles
  FOR EACH ROW EXECUTE FUNCTION public.qai_touch_updated_at();

DROP TRIGGER IF EXISTS trg_qai_conversation_touch ON public.ai_conversations;
CREATE TRIGGER trg_qai_conversation_touch
  BEFORE UPDATE ON public.ai_conversations
  FOR EACH ROW EXECUTE FUNCTION public.qai_touch_updated_at();

-- ============================================================
-- Vector indexes (cosine distance). Cheap while empty; HNSW keeps
-- semantic search fast once the Phase 6 pipeline fills embeddings.
-- ============================================================

CREATE INDEX IF NOT EXISTS product_ai_metadata_embedding_idx
  ON public.product_ai_metadata USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS store_ai_metadata_embedding_idx
  ON public.store_ai_metadata USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS recipes_embedding_idx
  ON public.recipes USING hnsw (embedding vector_cosine_ops);

COMMIT;

-- ============================================================
-- Verification (run after applying):
-- SELECT extname FROM pg_extension WHERE extname = 'vector';        -- 1 row
-- SELECT tablename FROM pg_tables WHERE schemaname='public'
--   AND tablename IN ('ai_events','customer_ai_profiles',
--     'product_ai_metadata','store_ai_metadata','recipes',
--     'recipe_product_matches','ai_conversations','ai_messages');    -- 8 rows
-- Every table above must have relrowsecurity = true:
-- SELECT relname, relrowsecurity FROM pg_class
--  WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'ai_%';
-- ============================================================
