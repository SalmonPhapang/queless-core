-- 20260922_qai_recipe_search.sql
--
-- Q AI Phase 5 — Recipe search, filters, budget + ingredient matching
-- (queless_ai_roadmap.md §9).
--
-- Tables `recipes` / `recipe_product_matches` already exist from
-- 20260922_qai_foundation.sql (3 seeded recipes). This migration adds:
--
--   1. recipes.estimated_cost     — SUM of best product match per ingredient,
--                                   maintained by qai_match_recipe_products().
--   2. qai_match_recipe_products  — the ingredient → product matching engine.
--     Normalised token scoring (singular/plural tolerant) against product
--     names/descriptions/categories/brand; seeded by merchandisers, safe to
--     re-run (DELETE + INSERT, deterministic rank-based scores). Budgets use
--     real prices on real products — nothing invented.
--   3. qai_search_recipes         — one RPC backing all search surfaces:
--     text search, cuisine filter, dietary filter, meal filter, max budget
--     filter. Uses searchable_text (ILIKE) with the Phase 6 upgrade path:
--     swap the ORDER BY to embedding <=> cosine when embeddings land.
--
-- Traps encoded from earlier phases: array appends cast ::text; triggers on
-- customer tables are guarded (this file adds none).

BEGIN;

ALTER TABLE public.recipes ADD COLUMN IF NOT EXISTS estimated_cost numeric;

-- ============================================================
-- Ingredient → product matching engine
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_match_recipe_products(p_recipe_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_recipe public.recipes%ROWTYPE;
  v_ing jsonb;
  v_name text;
  v_tokens text[];
  v_token text;
  v_best uuid;
  v_best_score numeric;
  v_score numeric;
  v_total numeric := 0;
  v_matched integer := 0;
BEGIN
  SELECT * INTO v_recipe FROM public.recipes WHERE id = p_recipe_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  DELETE FROM public.recipe_product_matches WHERE recipe_id = p_recipe_id;

  FOR v_ing IN SELECT * FROM jsonb_array_elements(COALESCE(v_recipe.ingredients, '[]'::jsonb)) LOOP
    v_name := LOWER(TRIM(COALESCE(v_ing->>'name', '')));
    CONTINUE WHEN v_name = '';

    -- normalise: singularise trailing 's', drop noise words
    v_tokens := ARRAY[]::text[];
    FOREACH v_token IN ARRAY regexp_split_to_array(v_name, '[^a-z]+') LOOP
      CONTINUE WHEN v_token IS NULL OR length(v_token) < 3;
      CONTINUE WHEN v_token = ANY (ARRAY['fresh','large','small','chopped','sliced','dried','ground','whole','piece','pieces','tin','can']);
      IF right(v_token, 1) = 's' AND length(v_token) > 3 THEN
        v_token := left(v_token, length(v_token) - 1);
      END IF;
      v_tokens := v_tokens || v_token::text;
    END LOOP;

    IF array_length(v_tokens, 1) IS NULL THEN
      CONTINUE;
    END IF;

    -- score every product, keep the best
    v_best := NULL;
    v_best_score := 0;
    SELECT p.id,
           SUM(CASE
             WHEN p.name ILIKE '%' || t || '%' THEN 3
             WHEN p.brand ILIKE '%' || t || '%' THEN 2
             WHEN p.category ILIKE '%' || t || '%' THEN 2
             WHEN p.description ILIKE '%' || t || '%' THEN 1
             ELSE 0
           END)::numeric
      INTO v_best, v_best_score
      FROM public.products p
      CROSS JOIN unnest(v_tokens) AS t
     WHERE t = ANY (v_tokens)
       AND lower(COALESCE(p.product_type, '')) <> 'alcohol'
     GROUP BY p.id
     ORDER BY 2 DESC, p.name
     LIMIT 1;

    v_best_score := COALESCE(v_best_score, 0);
    IF v_best IS NOT NULL AND v_best_score >= 3 THEN
      INSERT INTO public.recipe_product_matches
        (recipe_id, product_id, ingredient_name, match_score)
      VALUES
        (p_recipe_id, v_best, v_ing->>'name',
         LEAST(v_best_score / 9.0, 1.0));
      v_matched := v_matched + 1;
    END IF;
  END LOOP;

  -- estimated cost: best (cheapest) price per matched ingredient, at the
  -- app's user-facing price (12.5% Queless margin: floor(base*1.125)+0.99),
  -- matching Product.feeRate client-side. Raw DB prices are never shown.
  SELECT COALESCE(SUM((floor(best_price * 1.125) + 0.99)::numeric), 0) INTO v_total
  FROM (
    SELECT m.ingredient_name, MIN(p.price) AS best_price
    FROM public.recipe_product_matches m
    JOIN public.products p ON p.id = m.product_id
    WHERE m.recipe_id = p_recipe_id
    GROUP BY m.ingredient_name
  ) per_ingredient;

  UPDATE public.recipes
     SET estimated_cost = v_total
   WHERE id = p_recipe_id;

  RETURN v_matched;
END $fn$;

COMMENT ON FUNCTION public.qai_match_recipe_products(uuid) IS
  'Matches recipe ingredients to catalog products (token score >= 3 required). Returns matched ingredient count and updates recipes.estimated_cost. Re-runnable.';

-- ============================================================
-- Search RPC: text + cuisine + dietary + meal + budget in one call
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_search_recipes(
  p_query text DEFAULT NULL,
  p_cuisine text DEFAULT NULL,
  p_dietary text DEFAULT NULL,
  p_meal_type text DEFAULT NULL,
  p_max_cost numeric DEFAULT NULL,
  p_limit integer DEFAULT 10
)
RETURNS TABLE (
  id uuid,
  title text,
  description text,
  cuisine text,
  meal_type text,
  dietary_tags text[],
  difficulty text,
  prep_minutes integer,
  cook_minutes integer,
  servings integer,
  ingredient_count integer,
  estimated_cost numeric,
  match_count integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    r.id, r.title, r.description, r.cuisine, r.meal_type, r.dietary_tags,
    r.difficulty, r.prep_minutes, r.cook_minutes, r.servings,
    jsonb_array_length(COALESCE(r.ingredients, '[]'::jsonb)),
    r.estimated_cost,
    (SELECT count(*)::integer FROM public.recipe_product_matches m WHERE m.recipe_id = r.id)
  FROM public.recipes r
  WHERE (p_query IS NULL OR p_query = ''
         OR r.searchable_text ILIKE '%' || p_query || '%'
         OR r.title ILIKE '%' || p_query || '%')
    AND (p_cuisine IS NULL OR p_cuisine = ''
         OR lower(r.cuisine) = lower(p_cuisine))
    AND (p_dietary IS NULL OR p_dietary = ''
         OR p_dietary = ANY (r.dietary_tags))
    AND (p_meal_type IS NULL OR p_meal_type = ''
         OR lower(r.meal_type) = lower(p_meal_type))
    -- budget honesty: when a max cost is given, only recipes with a KNOWN
    -- positive estimated cost may pass. Unknown/unpriced is excluded.
    AND (p_max_cost IS NULL
         OR (r.estimated_cost IS NOT NULL AND r.estimated_cost > 0
             AND r.estimated_cost <= p_max_cost))
  ORDER BY
    CASE WHEN p_query IS NOT NULL AND p_query <> ''
         THEN (CASE WHEN r.title ILIKE '%' || p_query || '%' THEN 0 ELSE 1 END)
         ELSE 1 END,
    r.title
  LIMIT GREATEST(p_limit, 1);
$fn$;

REVOKE ALL ON FUNCTION public.qai_search_recipes(text, text, text, text, numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qai_search_recipes(text, text, text, text, numeric, integer) TO authenticated, anon;

-- ============================================================
-- Bulk runner: match every recipe (idempotent)
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_match_all_recipes()
RETURNS TABLE (recipe_id uuid, matched integer, estimated_cost numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT id FROM public.recipes LOOP
    BEGIN
      PERFORM public.qai_match_recipe_products(r.id);
      RETURN QUERY SELECT r.id,
        (SELECT count(*)::integer FROM public.recipe_product_matches m WHERE m.recipe_id = r.id),
        (SELECT estimated_cost FROM public.recipes WHERE id = r.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'matching failed for recipe %: %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN;
END $fn$;

COMMIT;
