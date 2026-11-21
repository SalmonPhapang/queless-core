-- ============================================================================
-- Follow-up to 20261121_support_tickets_and_faq.sql
--
-- The shared database already had support_articles from the first migration.
-- This adds the same embedding columns the other Q AI tables use and teaches
-- both embedding workers (SQL built-in + ai-embed Edge Function) about the
-- published help-centre content.
-- ============================================================================

ALTER TABLE public.support_articles
  ADD COLUMN IF NOT EXISTS searchable_text text NULL,
  ADD COLUMN IF NOT EXISTS embedding vector(768) NULL,
  ADD COLUMN IF NOT EXISTS embedding_model text NULL,
  ADD COLUMN IF NOT EXISTS embedded_at timestamptz NULL;

UPDATE public.support_articles
   SET searchable_text = question || E'\n' || answer_md
 WHERE searchable_text IS NULL
    OR searchable_text = '';

-- Keep the built-in crawler in sync with ai-embed's TARGETS list.
CREATE OR REPLACE FUNCTION public.qai_embed_batch(p_batch integer DEFAULT 200)
RETURNS TABLE(target text, target_id uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_done integer := 0;
  r record;
BEGIN
  FOR r IN
    SELECT m.product_id AS id, m.searchable_text AS st
    FROM public.product_ai_metadata m
    WHERE m.embedded_at IS NULL OR m.embedding IS NULL
    ORDER BY m.product_id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_done >= p_batch;
    UPDATE public.product_ai_metadata
       SET embedding = public.qai_embed_text(r.st),
           embedding_model = 'builtin-hash-768-v1',
           embedded_at = now()
     WHERE product_id = r.id;
    v_done := v_done + 1;
    target := 'product'; target_id := r.id; status := 'embedded';
    RETURN NEXT;
  END LOOP;

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

  FOR r IN
    SELECT a.id AS id, a.searchable_text AS st
    FROM public.support_articles a
    WHERE a.status = 'published'
      AND (a.embedded_at IS NULL OR a.embedding IS NULL)
      AND a.searchable_text IS NOT NULL
    ORDER BY a.id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_done >= p_batch;
    UPDATE public.support_articles
       SET embedding = public.qai_embed_text(r.st),
           embedding_model = 'builtin-hash-768-v1',
           embedded_at = now()
     WHERE id = r.id;
    v_done := v_done + 1;
    target := 'support_article'; target_id := r.id; status := 'embedded';
    RETURN NEXT;
  END LOOP;
END;
$function$;
