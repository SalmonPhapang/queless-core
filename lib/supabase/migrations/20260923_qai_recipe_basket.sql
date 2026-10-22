-- ============================================================================
-- Phase 12 — Recipe → Cart (single-store MVP, grocery-first)
--
-- qai_recipe_store_coverage(p_recipe_id, p_store_id?) is the one RPC the
-- "Add all ingredients" flow needs. It:
--
--   1. Picks ONE store:
--        · p_store_id if given (explicit choice),
--        · otherwise the best-coverage store, preferring grocery categories
--          (grocery/supermarket/spars/food market/convenience) once any exist
--          — today's catalog is all restaurants, so the fallback keeps the
--          flow usable and the grocery preference activates automatically
--          when a grocery store onboards.
--   2. Matches recipe ingredients to that store's products via
--      qai_recipe_store_rank (token-overlap scoring per ingredient).
--   3. Returns the matched product rows as full jsonb (to_jsonb(p.*)) so the
--      app can parse them straight into Product and add them to the cart,
--      plus the ingredients that could NOT be found at that store (missing),
--      and an estimated_cost.
--
-- If no store has any match, returns zero rows — the UI explains honestly.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.qai_recipe_store_coverage(
  p_recipe_id uuid,
  p_store_id uuid DEFAULT NULL
)
RETURNS TABLE (
  store_id uuid,
  store_name text,
  matched_count integer,
  total_ingredients integer,
  estimated_cost numeric,
  missing jsonb,
  products jsonb
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
AS $fn$
DECLARE
  v_total integer := 0;
  v_pick record;
  v_ranked bigint;
BEGIN
  -- Recipe must exist with a well-formed ingredients array.
  IF NOT EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = p_recipe_id AND jsonb_typeof(r.ingredients) = 'array'
  ) THEN
    RETURN;
  END IF;

  SELECT count(*)::integer INTO v_total
  FROM jsonb_array_elements((SELECT ingredients FROM public.recipes WHERE id = p_recipe_id)) ing
  WHERE jsonb_typeof(ing) = 'object'
    AND NULLIF(LOWER(TRIM(COALESCE(ing->>'name', ''))), '') IS NOT NULL;

  IF v_total = 0 THEN
    RETURN;
  END IF;

  -- Candidate stores: any approved store with ≥1 match for this recipe,
  -- plus the explicitly requested store (even with zero matches).
  WITH candidates AS (
    SELECT DISTINCT m.store_id
    FROM public.recipe_product_matches m
    JOIN public.stores s ON s.id = m.store_id AND s.is_approved
    WHERE m.recipe_id = p_recipe_id
    UNION
    SELECT p_store_id
    WHERE p_store_id IS NOT NULL
  ),
  scored AS (
    SELECT
      c.store_id,
      s.name AS store_name,
      CASE WHEN s.category ILIKE ANY (ARRAY[
        '%grocery%', '%supermarket%', '%spar%', '%food market%',
        '%convenience%', '%butcher%', '%bakery%'
      ]) THEN 1 ELSE 0 END AS is_grocery,
      rk.matched,
      rk.cost
    FROM candidates c
    JOIN public.stores s ON s.id = c.store_id AND s.is_approved
    CROSS JOIN LATERAL (
      SELECT
        count(*)::integer AS matched,
        COALESCE(sum((floor(rr.price * 1.125) + 0.99)::numeric), 0)::numeric AS cost
        -- cost uses the app's user-facing price convention (12.5% Queless
        -- margin: floor(base*1.125)+0.99), matching Product.feeRate client-side.
      FROM public.qai_recipe_store_rank(p_recipe_id, c.store_id) rr
    ) rk
    WHERE s.category NOT ILIKE '%liquor%' -- grocery basket is food; liquor-only stores excluded
  )
  SELECT store_id, store_name, matched, cost
  INTO v_pick
  FROM scored
  ORDER BY matched DESC, is_grocery DESC, cost ASC, store_name ASC
  LIMIT 1;

  IF v_pick IS NULL OR v_pick.store_id IS NULL THEN
    RETURN;
  END IF;

  SELECT count(*) INTO v_ranked
  FROM public.qai_recipe_store_rank(p_recipe_id, v_pick.store_id);

  IF v_ranked = 0 THEN
    RETURN;
  END IF;

  store_id := v_pick.store_id;
  store_name := v_pick.store_name;
  matched_count := v_ranked::integer;
  total_ingredients := v_total;
  estimated_cost := v_pick.cost;

  -- Ingredients with no product at the chosen store.
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object('name', ing->>'name', 'quantity', ing->>'quantity') ORDER BY ing->>'name'),
    '[]'::jsonb
  ) INTO missing
  FROM jsonb_array_elements((SELECT ingredients FROM public.recipes WHERE id = p_recipe_id)) ing
  WHERE jsonb_typeof(ing) = 'object'
    AND NULLIF(LOWER(TRIM(COALESCE(ing->>'name', ''))), '') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.qai_recipe_store_rank(p_recipe_id, v_pick.store_id) rr
      WHERE rr.ingredient_name = LOWER(TRIM(ing->>'name'))
    );

  -- Full product rows for the matched items (app parses these into Product).
  SELECT COALESCE(
    jsonb_agg(to_jsonb(p) ORDER BY rr.ingredient_name),
    '[]'::jsonb
  ) INTO products
  FROM public.qai_recipe_store_rank(p_recipe_id, v_pick.store_id) rr
  JOIN public.products p ON p.id = rr.product_id;

  RETURN NEXT;
END;
$fn$;

-- Make both functions callable by the app's authenticated users.
-- They're SECURITY DEFINER so the internal anti-join / join paths run with the
-- owner's rights and are not blocked by RLS on recipes/products/stores.
GRANT EXECUTE ON FUNCTION public.qai_recipe_store_coverage(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qai_recipe_store_coverage(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qai_recipe_store_rank(uuid, uuid) TO anon, authenticated;
