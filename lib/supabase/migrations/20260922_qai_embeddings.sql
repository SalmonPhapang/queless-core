-- ============================================================================
-- Phase 6 — Embedding Pipeline (Q AI roadmap §10)
--
-- Design (two tiers, one queue):
--   * Tier 1 (always available): public.qai_embed_text() — a deterministic,
--     self-contained 768-dim hashing embedder (word unigrams + character
--     trigrams, signed feature hashing, L2-normalised). Runs entirely in SQL,
--     so pg_cron can drain the queue with no HTTP hop and no secrets.
--   * Tier 2 (future): the `ai-embed` edge function runs the same queue with
--     a real model (Ollama / any OpenAI-compatible embeddings endpoint) as
--     soon as one is configured. Re-running embeddings replaces vectors and
--     stamps them with the model name — no structural change needed.
--
-- Every embedded row is stamped with embedding_model + embedded_at, so mixed
-- model states are always visible and a model switch is a re-run, not a
-- migration.
--
-- Staleness triggers clear the stamp when searchable_text changes (which the
-- Phase 4 sync triggers fire on every catalog edit), keeping the queue
-- self-maintaining.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Stamp columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.product_ai_metadata
  ADD COLUMN IF NOT NULL embedded_at timestamptz,
  ADD COLUMN IF NOT NULL embedding_model text;

ALTER TABLE public.store_ai_metadata
  ADD COLUMN IF NOT NULL embedded_at timestamptz,
  ADD COLUMN IF NOT NULL embedding_model text;

ALTER TABLE public.recipes
  ADD COLUMN IF NOT NULL embedded_at timestamptz,
  ADD COLUMN IF NOT NULL embedding_model text;

-- ---------------------------------------------------------------------------
-- 2. Built-in deterministic embedder (Tier 1)
--
--   features  = word unigrams (w 1.0) + per-word character trigrams (w 0.3),
--               TF-weighted
--   hashing   = signed feature hashing: md5(feature) → bucket in [0,768),
--               sign from a second hash nibble
--   output    = L2-normalised vector(768)
--
-- Deterministic and version-stable (md5 is a fixed algorithm), so embeddings
-- are reproducible across machines and reconnects.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_embed_text(p_text text)
RETURNS public.vector
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
WITH norm AS (
  SELECT regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', ' ', 'g') AS t
),
words AS (
  SELECT trim(x) AS w
  FROM norm, regexp_split_to_table(t, '\s+') AS x
  WHERE length(trim(x)) >= 2 AND trim(x) ~ '[a-z0-9]'
),
uni AS (
  SELECT w AS feature, 1.0::float8 AS wgt, count(*)::float8 AS tf FROM words GROUP BY w
),
tri AS (
  SELECT substr(w, g, 3) AS feature, 0.3::float8 AS wgt, count(*)::float8 AS tf
  FROM words, generate_series(1, greatest(length(w) - 2, 1)) AS g
  GROUP BY 1
),
feats AS (
  SELECT feature, sum(wgt * tf) AS v
  FROM (SELECT * FROM uni UNION ALL SELECT * FROM tri) f
  GROUP BY feature
),
hashed AS (
  SELECT
    (abs((('x' || substr(md5(feature), 1, 8))::bit(32)::int)::bigint) % 768) AS idx,
    CASE WHEN (('x' || substr(md5(feature), 9, 1))::bit(4)::int) % 2 = 1
         THEN -1.0 ELSE 1.0 END * v AS contrib
  FROM feats
),
bucketed AS (
  SELECT idx, sum(contrib) AS val FROM hashed GROUP BY idx
),
nrm AS (
  SELECT coalesce(sqrt(sum(val * val)), 1.0) AS s FROM bucketed
)
SELECT (
  '[' || string_agg(
    coalesce(round((b.val / n.s)::numeric, 6)::text, '0'),
    ',' ORDER BY d.i
  ) || ']'
)::public.vector
FROM generate_series(0, 767) AS d(i)
LEFT JOIN bucketed b ON b.idx = d.i
CROSS JOIN nrm n
$$;

-- ---------------------------------------------------------------------------
-- 3. Batch processor — drains pending docs for all three targets.
--    SECURITY DEFINER so pg_cron (non-superuser schedules) and the edge
--    function can run it; execute revoked from PUBLIC/anon/authenticated.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_embed_batch(p_batch integer DEFAULT 200)
RETURNS TABLE(target text, target_id uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_done integer := 0;
  r record;
BEGIN
  -- products
  FOR r IN
    SELECT m.product_id AS id, m.searchable_text AS st
    FROM public.product_ai_metadata m
    WHERE m.embedded_at IS NULL OR m.embedding IS NULL
    ORDER BY m.product_id
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.product_ai_metadata
       SET embedding = public.qai_embed_text(r.st),
           embedding_model = 'builtin-hash-768-v1',
           embedded_at = now()
     WHERE product_id = r.id;
    v_done := v_done + 1;
    target := 'product'; target_id := r.id; status := 'embedded';
    RETURN NEXT;
    EXIT WHEN v_done >= p_batch;
  END LOOP;

  -- stores
  FOR r IN
    SELECT m.store_id AS id, m.searchable_text AS st
    FROM public.store_ai_metadata m
    WHERE m.embedded_at IS NULL OR m.embedding IS NULL
    ORDER BY m.store_id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_done >= p_batch;
    UPDATE public.store_ai_metadata
       SET embedding = public.qai_embed_text(r.st),
           embedding_model = 'builtin-hash-768-v1',
           embedded_at = now()
     WHERE store_id = r.id;
    v_done := v_done + 1;
    target := 'store'; target_id := r.id; status := 'embedded';
    RETURN NEXT;
  END LOOP;

  -- recipes
  FOR r IN
    SELECT rc.id AS id, rc.searchable_text AS st
    FROM public.recipes rc
    WHERE rc.embedded_at IS NULL OR rc.embedding IS NULL
    ORDER BY rc.id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_done >= p_batch;
    UPDATE public.recipes
       SET embedding = public.qai_embed_text(r.st),
           embedding_model = 'builtin-hash-768-v1',
           embedded_at = now()
     WHERE id = r.id;
    v_done := v_done + 1;
    target := 'recipe'; target_id := r.id; status := 'embedded';
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.qai_embed_batch(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qai_embed_batch(integer) FROM anon;
REVOKE ALL ON FUNCTION public.qai_embed_batch(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.qai_embed_batch(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Staleness triggers — searchable_text change ⇒ re-embed needed.
--    (The Phase 4 sync triggers fire these on every catalog edit.)
--    NOTE: UPDATE OF searchable_text only — the embed writeback touches
--    embedding/embedded_at/embedding_model and must NOT invalidate itself.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_embedding_invalidate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.embedding := NULL;
  NEW.embedded_at := NULL;
  NEW.embedding_model := NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_qai_product_meta_embed_stale ON public.product_ai_metadata;
CREATE TRIGGER trg_qai_product_meta_embed_stale
  BEFORE UPDATE OF searchable_text ON public.product_ai_metadata
  FOR EACH ROW EXECUTE FUNCTION public.qai_embedding_invalidate();

DROP TRIGGER IF EXISTS trg_qai_store_meta_embed_stale ON public.store_ai_metadata;
CREATE TRIGGER trg_qai_store_meta_embed_stale
  BEFORE UPDATE OF searchable_text ON public.store_ai_metadata
  FOR EACH ROW EXECUTE FUNCTION public.qai_embedding_invalidate();

DROP TRIGGER IF EXISTS trg_qai_recipe_embed_stale ON public.recipes;
CREATE TRIGGER trg_qai_recipe_embed_stale
  BEFORE UPDATE OF searchable_text ON public.recipes
  FOR EACH ROW EXECUTE FUNCTION public.qai_embedding_invalidate();

-- ---------------------------------------------------------------------------
-- 5. Status view — one place to see queue health across all three targets.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.qai_embedding_status AS
SELECT 'product' AS target,
       count(*) AS total,
       count(*) FILTER (WHERE embedded_at IS NOT NULL AND embedding IS NOT NULL) AS embedded,
       count(*) FILTER (WHERE embedded_at IS NULL OR embedding IS NULL) AS pending,
       max(embedded_at) AS last_embedded_at,
       (array_agg(embedding_model) FILTER (WHERE embedding_model IS NOT NULL))[1] AS model
FROM public.product_ai_metadata
UNION ALL
SELECT 'store',
       count(*),
       count(*) FILTER (WHERE embedded_at IS NOT NULL AND embedding IS NOT NULL),
       count(*) FILTER (WHERE embedded_at IS NULL OR embedding IS NULL),
       max(embedded_at),
       (array_agg(embedding_model) FILTER (WHERE embedding_model IS NOT NULL))[1]
FROM public.store_ai_metadata
UNION ALL
SELECT 'recipe',
       count(*),
       count(*) FILTER (WHERE embedded_at IS NOT NULL AND embedding IS NOT NULL),
       count(*) FILTER (WHERE embedded_at IS NULL OR embedding IS NULL),
       max(embedded_at),
       (array_agg(embedding_model) FILTER (WHERE embedding_model IS NOT NULL))[1]
FROM public.recipes;

GRANT SELECT ON public.qai_embedding_status TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Schedules (pg_cron). The embedding job drains the Phase 6 queue; the
--    affinity job closes the Phase 3 ops TODO (affinity profiles were only
--    refreshing on manual processor runs).
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('qai-embed-pipeline')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'qai-embed-pipeline');
SELECT cron.schedule('qai-embed-pipeline', '*/15 * * * *', 'SELECT public.qai_embed_batch(200);');

SELECT cron.unschedule('qai-affinity-jobs')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'qai-affinity-jobs');
SELECT cron.schedule('qai-affinity-jobs', '*/5 * * * *', 'SELECT public.qai_process_affinity_jobs();');
