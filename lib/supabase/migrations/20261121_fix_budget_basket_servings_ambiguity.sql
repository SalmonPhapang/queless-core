-- Fix ambiguous `servings` reference in qai_build_budget_basket.
-- The RETURNS TABLE column `servings` collided with public.recipes.servings
-- when the recipe-serving warning SELECT was unqualified (Postgres 42702).
-- Qualify the table column as r.servings.

CREATE OR REPLACE FUNCTION public.qai_build_budget_basket(
  p_recipe_id uuid    DEFAULT NULL,
  p_products  jsonb   DEFAULT NULL,
  p_budget    numeric DEFAULT NULL,
  p_servings  integer DEFAULT NULL
)
RETURNS TABLE (
  store_id         uuid,
  store_name       text,
  item_count       integer,
  total_cost       numeric,
  per_person_cost  numeric,
  servings         integer,
  within_budget    boolean,
  budget_headroom  numeric,
  missing          jsonb,
  products         jsonb,
  warning          text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_budget    numeric := COALESCE(p_budget, 0);
  v_servings  integer := GREATEST(COALESCE(p_servings, 1), 1);
  v_warning   text    := '';
BEGIN
  -- Recipe basket path — reuse Phase 12's store coverage logic then
  -- layer the budget/servings overlay on top.
  IF p_recipe_id IS NOT NULL THEN
    DECLARE
      v_cov record;
      v_cost numeric;
    BEGIN
      SELECT * INTO v_cov
        FROM public.qai_recipe_store_coverage(p_recipe_id, NULL)
        LIMIT 1;

      IF v_cov IS NULL OR v_cov.store_id IS NULL THEN
        store_id         := NULL;
        store_name       := '';
        item_count       := 0;
        total_cost       := 0;
        per_person_cost  := 0;
        servings         := v_servings;
        within_budget    := v_budget = 0;
        budget_headroom  := v_budget;
        missing          := '[]'::jsonb;
        products         := '[]'::jsonb;
        warning          := 'No approved Queless store currently has ingredients for this recipe. Try a simpler recipe or the kasi combo option.';
        RETURN NEXT;
        RETURN;
      END IF;

      v_cost := COALESCE(v_cov.estimated_cost, 0)::numeric;

      -- Servings honesty: we quote the basket as-is (the recipe's native
      -- servings), plus a /person calculation. If the user's servings
      -- differ from the recipe's, we call that out in the warning so the
      -- UI can show the scale message.
      v_warning := '';
      IF p_servings IS NOT NULL AND (v_cov.total_ingredients IS NOT NULL) THEN
        -- Recipe servings live on the recipes row; qualify it to avoid
        -- colliding with the RETURNS TABLE column of the same name.
        DECLARE
          v_recipe_srv integer;
        BEGIN
          SELECT COALESCE(r.servings, 2) INTO v_recipe_srv
            FROM public.recipes AS r WHERE r.id = p_recipe_id;
          IF v_recipe_srv <> p_servings THEN
            v_warning := format(
              'This recipe serves %s; your request was for %s. The basket below is for the full recipe — scale quantities at checkout.',
              v_recipe_srv, p_servings
            );
          END IF;
        END;
      END IF;

      store_id         := v_cov.store_id;
      store_name       := v_cov.store_name;
      item_count       := v_cov.matched_count;
      total_cost       := ROUND(v_cost, 2);
      servings         := v_servings;
      per_person_cost  := CASE WHEN v_servings > 0 AND v_cost > 0
                               THEN ROUND(v_cost / v_servings::numeric, 2) ELSE 0 END;
      within_budget    := (v_budget = 0) OR (v_cost <= v_budget);
      budget_headroom  := v_budget - v_cost;
      missing          := COALESCE(v_cov.missing, '[]'::jsonb);
      products         := COALESCE(v_cov.products, '[]'::jsonb);
      warning          := v_warning;
      RETURN NEXT;
      RETURN;
    END;
  END IF;

  -- Standalone products path — user passed an explicit product list.
  IF p_products IS NOT NULL AND jsonb_typeof(p_products) = 'array' AND jsonb_array_length(p_products) > 0 THEN
    DECLARE
      v_total numeric := 0;
      v_cnt   integer := 0;
      v_picks jsonb[] := ARRAY[]::jsonb[];
      v_miss  jsonb[] := ARRAY[]::jsonb[];
      v_store uuid   := NULL;
      v_sname text   := '';
      r       record;
    BEGIN
      FOR r IN
        SELECT
          (elem->>'product_id')::uuid AS pid,
          COALESCE((elem->>'quantity')::integer, 1) AS qty
        FROM jsonb_array_elements(p_products) AS elem
      LOOP
        DECLARE
          v_p record;
          v_qty integer;
        BEGIN
          v_qty := GREATEST(r.qty, 1);
          SELECT p.id, p.name, p.store_id, p.price, s.name AS store_n
            INTO v_p
            FROM public.products p
            JOIN public.stores s ON s.id = p.store_id
           WHERE p.id = r.pid;
          IF v_p IS NULL THEN
            v_miss := array_append(v_miss, jsonb_build_object('product_id', r.pid, 'reason', 'not_found'));
            CONTINUE;
          END IF;
          v_store := COALESCE(v_store, v_p.store_id);
          v_sname := COALESCE(NULLIF(v_sname, ''), v_p.store_n);
          -- Cross-store: we only build coherent single-store baskets today.
          IF v_p.store_id <> v_store THEN
            v_miss := array_append(v_miss, jsonb_build_object(
              'product_id', r.pid, 'name', v_p.name,
              'reason', format('different_store: %s', v_p.store_n)
            ));
            CONTINUE;
          END IF;
          v_picks := array_append(v_picks, to_jsonb(v_p) || jsonb_build_object('quantity', v_qty));
          v_total := v_total + (floor(v_p.price * 1.125) + 0.99)::numeric * v_qty;
          v_cnt   := v_cnt + v_qty;
        END;
      END LOOP;

      store_id         := v_store;
      store_name       := COALESCE(v_sname, '');
      item_count       := v_cnt;
      total_cost       := ROUND(v_total, 2);
      servings         := v_servings;
      per_person_cost  := CASE WHEN v_servings > 0 AND v_total > 0
                               THEN ROUND(v_total / v_servings::numeric, 2) ELSE 0 END;
      within_budget    := (v_budget = 0) OR (v_total <= v_budget);
      budget_headroom  := v_budget - v_total;
      missing          := to_jsonb(ARRAY(SELECT unnest(v_miss)));
      products         := to_jsonb(ARRAY(SELECT unnest(v_picks)));
      warning          := CASE WHEN v_store IS NULL THEN 'No products could be found.' ELSE '' END;
      RETURN NEXT;
      RETURN;
    END;
  END IF;

  -- No inputs: return a single informative empty row.
  store_id         := NULL;
  store_name       := '';
  item_count       := 0;
  total_cost       := 0;
  per_person_cost  := 0;
  servings         := v_servings;
  within_budget    := v_budget = 0;
  budget_headroom  := v_budget;
  missing          := '[]'::jsonb;
  products         := '[]'::jsonb;
  warning          := 'Pass either a recipe_id or a products array to build the basket.';
  RETURN NEXT;
END;
$fn$;

COMMENT ON FUNCTION public.qai_build_budget_basket(uuid, jsonb, numeric, integer) IS
  'Phase 15 budget basket builder. Builds the actual Queless basket for a recipe (reusing qai_recipe_store_coverage) or for an explicit product list, with budget and per-person overlay. Rows include a warning when the recipe servings differ from the user requested servings or when cross-store products are dropped.';

GRANT EXECUTE ON FUNCTION public.qai_build_budget_basket(uuid, jsonb, numeric, integer) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.qai_build_budget_basket(uuid, jsonb, numeric, integer) FROM PUBLIC;
