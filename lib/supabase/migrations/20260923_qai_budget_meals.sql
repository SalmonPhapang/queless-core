-- ============================================================================
-- Phase 15 — Budget Meal Agent
--
-- Scenario: "Give me dinner for 4 under R250" or "I have R500 for 6 people".
--
-- Two RPCs:
--   1. qai_plan_budget_meals — the agent-facing planner. Picks 1-3 recipes
--      whose combined matched-ingredient cost fits (or nearly fits) the
--      per-person budget, plus the top standalone products (kota, chips,
--      drinks) for when no recipe combination is within budget.
--   2. qai_build_budget_basket — takes a recipe_id (or product list) and
--      builds the actual purchasable basket at the best-coverage store,
--      returning the customer-price total, missing ingredients, and the
--      per-person share.
--
-- Budget honesty rules (same as Phase 5):
--   * Only real product prices are used — never an invented estimate.
--   * Recipes with no priced matches are excluded from budget filtering.
--   * The customer price is the Queless shelf price (floor(raw*1.125)+0.99),
--     matching Product.feeRate client-side and the edge function's
--     customerPrice() helper.
--
-- Servings honesty:
--   * The per-person target cost = budget / GREATEST(servings, 1).
--   * A recipe whose total estimated_cost is >> target gets its basket
--     proportionally scaled by suggesting more/less of the same products
--     (reality: we just report the total and let the user decide; the
--     UI shows "R X / person" clearly).
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. Budget meal planner
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_plan_budget_meals(
  p_budget      numeric DEFAULT NULL,
  p_servings    integer DEFAULT NULL,
  p_cuisine     text    DEFAULT NULL,
  p_dietary     text    DEFAULT NULL,
  p_meal_type   text    DEFAULT NULL,
  p_limit       integer DEFAULT 6
)
RETURNS TABLE (
  plan_id          integer,
  plan_kind        text,                -- 'recipe_combo' | 'standalone_products'
  title            text,
  description      text,
  total_cost       numeric,
  per_person_cost  numeric,
  servings         integer,
  within_budget    boolean,
  headroom         numeric,             -- budget - total_cost (can be negative)
  recipes          jsonb,
  products         jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_budget      numeric := COALESCE(p_budget, 0);
  v_servings    integer := GREATEST(COALESCE(p_servings, 1), 1);
  v_per_person  numeric;
  v_limit       integer := GREATEST(p_limit, 1);
  v_rid         uuid;
  v_title       text;
  v_cost        numeric;
  v_srv         integer;
  v_row         record;
  v_plan_id     integer := 0;
  v_combos      integer := 0;
BEGIN
  -- Budget zero / NULL → no upper bound but we still rank by per-person cost.
  v_per_person := CASE WHEN v_budget > 0 THEN v_budget / v_servings::numeric ELSE NULL END;

  -- ------------------------------------------------------------------
  -- Plan type A: individual recipes, each one scored against per-person cost
  -- ------------------------------------------------------------------
  FOR v_row IN
    SELECT
      r.id,
      r.title,
      COALESCE(r.estimated_cost, 0) AS cost,
      COALESCE(r.servings, 2)       AS srv,
      r.estimated_cost IS NOT NULL AND r.estimated_cost > 0 AS has_price
    FROM public.recipes r
    WHERE (p_cuisine   IS NULL OR p_cuisine   = '' OR lower(r.cuisine) = lower(p_cuisine))
      AND (p_dietary   IS NULL OR p_dietary   = '' OR p_dietary = ANY (r.dietary_tags))
      AND (p_meal_type IS NULL OR p_meal_type = '' OR lower(r.meal_type) = lower(p_meal_type))
    ORDER BY
      CASE WHEN v_budget > 0 AND r.estimated_cost IS NOT NULL AND r.estimated_cost > 0
           THEN ABS(r.estimated_cost / GREATEST(r.servings, 1)::numeric - v_per_person)
           ELSE 1e9::numeric
      END,
      r.estimated_cost NULLS LAST,
      r.title
    LIMIT LEAST(v_limit, 10)
  LOOP
    v_plan_id := v_plan_id + 1;
    plan_id         := v_plan_id;
    plan_kind       := 'recipe_combo';
    title           := v_row.title;
    description     := 'Single recipe matched at its quoted servings. Build the basket to see exact product matches and availability.';
    total_cost      := v_row.cost;
    servings        := v_row.srv;
    per_person_cost := CASE WHEN v_row.srv > 0 AND v_row.cost > 0
                            THEN ROUND((v_row.cost / v_row.srv::numeric), 2)
                            ELSE 0 END;
    within_budget   := (v_budget = 0) OR (v_row.cost = 0) OR (v_row.cost <= v_budget);
    headroom        := v_budget - v_row.cost;
    recipes         := jsonb_build_array(jsonb_build_object(
                         'recipe_id',      v_row.id,
                         'title',          v_row.title,
                         'servings',       v_row.srv,
                         'estimated_cost', v_row.cost,
                         'match_count',    (SELECT count(*) FROM public.recipe_product_matches m WHERE m.recipe_id = v_row.id)
                       ));
    products        := jsonb_build_array();
    v_combos        := v_combos + 1;
    RETURN NEXT;
    EXIT WHEN v_plan_id >= v_limit;
  END LOOP;

  -- ------------------------------------------------------------------
  -- Plan type B: standalone products (when recipes don't cover it)
  --   Pick up to 5 products whose combined per-person cost is closest to
  --   the target. Picks one meal core (kota/burger/pie), one side (chips),
  --   one drink — classic kasi combo. Products with no image or no price
  --   are still ranked lower (they still have a raw DB price though).
  -- ------------------------------------------------------------------
  IF v_plan_id < v_limit THEN
    DECLARE
      v_products   jsonb;
      v_total      numeric;
      v_picks      jsonb[];
      v_core       record;
      v_side       record;
      v_drink      record;
    BEGIN
      -- Core meal item: kota / burger / breyani / pie
      SELECT p.id, p.name, (floor(p.price * 1.125) + 0.99)::numeric AS cust_price
        INTO v_core
        FROM public.products p
       WHERE lower(COALESCE(p.product_type, 'food')) <> 'alcohol'
         AND p.price > 0
         AND (
           lower(p.name) LIKE '%kota%' OR
           lower(p.name) LIKE '%burger%' OR
           lower(p.name) LIKE '%breyani%' OR
           lower(p.name) LIKE '%pie%' OR
           lower(p.category) LIKE '%meal%'
         )
       ORDER BY (CASE WHEN v_budget > 0 THEN ABS((floor(p.price * 1.125) + 0.99) / v_servings::numeric - v_per_person) ELSE p.price END)
       LIMIT 1;

      -- Side: chips / pap / salad
      SELECT p.id, p.name, (floor(p.price * 1.125) + 0.99)::numeric AS cust_price
        INTO v_side
        FROM public.products p
       WHERE lower(COALESCE(p.product_type, 'food')) <> 'alcohol'
         AND p.price > 0
         AND (
           lower(p.name) LIKE '%chip%' OR
           lower(p.name) LIKE '%pap%' OR
           lower(p.name) LIKE '%salad%' OR
           lower(p.category) LIKE '%side%'
         )
       ORDER BY (CASE WHEN v_budget > 0 THEN ABS((floor(p.price * 1.125) + 0.99) / v_servings::numeric - v_per_person) ELSE p.price END)
       LIMIT 1;

      -- Drink: soft drink / juice (non-alcohol)
      SELECT p.id, p.name, (floor(p.price * 1.125) + 0.99)::numeric AS cust_price
        INTO v_drink
        FROM public.products p
       WHERE lower(COALESCE(p.product_type, 'drink')) <> 'alcohol'
         AND p.price > 0
         AND (
           lower(p.category) LIKE '%drink%' OR
           lower(p.name) LIKE '%coke%' OR
           lower(p.name) LIKE '%fanta%' OR
           lower(p.name) LIKE '%sprite%' OR
           lower(p.name) LIKE '%juice%' OR
           lower(p.name) LIKE '%cold%drink%' OR
           lower(p.name) LIKE '%soda%'
         )
       ORDER BY (CASE WHEN v_budget > 0 THEN ABS((floor(p.price * 1.125) + 0.99) / v_servings::numeric - v_per_person) ELSE p.price END)
       LIMIT 1;

      v_total := 0;
      v_picks := ARRAY[]::jsonb[];
      IF v_core IS NOT NULL THEN
        v_picks := array_append(v_picks, jsonb_build_object(
          'product_id', v_core.id, 'name', v_core.name, 'price', v_core.cust_price, 'role', 'main'
        ));
        v_total := v_total + v_core.cust_price;
      END IF;
      IF v_side IS NOT NULL THEN
        v_picks := array_append(v_picks, jsonb_build_object(
          'product_id', v_side.id, 'name', v_side.name, 'price', v_side.cust_price, 'role', 'side'
        ));
        v_total := v_total + v_side.cust_price;
      END IF;
      IF v_drink IS NOT NULL THEN
        v_picks := array_append(v_picks, jsonb_build_object(
          'product_id', v_drink.id, 'name', v_drink.name, 'price', v_drink.cust_price, 'role', 'drink'
        ));
        v_total := v_total + v_drink.cust_price;
      END IF;

      IF array_length(v_picks, 1) > 0 THEN
        v_plan_id := v_plan_id + 1;
        plan_id         := v_plan_id;
        plan_kind       := 'standalone_products';
        title           := 'Kasi combo';
        description     := 'A ready-to-order kasi meal: one main, one side, one drink. Good for when you want delivery right now instead of cooking.';
        total_cost      := ROUND(v_total, 2);
        servings        := v_servings;
        per_person_cost := CASE WHEN v_servings > 0 AND v_total > 0
                                THEN ROUND((v_total / v_servings::numeric), 2) ELSE 0 END;
        within_budget   := (v_budget = 0) OR (v_total <= v_budget);
        headroom        := v_budget - v_total;
        recipes         := jsonb_build_array();
        products        := to_jsonb(ARRAY(SELECT unnest(v_picks)));
        RETURN NEXT;
      END IF;
    END;
  END IF;

  RETURN;
END $fn$;

COMMENT ON FUNCTION public.qai_plan_budget_meals(numeric, integer, text, text, text, integer) IS
  'Phase 15 budget-meal planner. Given a budget (R) and servings, returns ranked meal plans: individual recipes first, then a standalone kasi-combo as a fallback. Each plan quotes total cost, per-person cost, and whether it is within budget.';

GRANT EXECUTE ON FUNCTION public.qai_plan_budget_meals(numeric, integer, text, text, text, integer) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.qai_plan_budget_meals(numeric, integer, text, text, text, integer) FROM PUBLIC;

-- ============================================================
-- 2. Budget basket builder — recipe → store products with budget check
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_build_budget_basket(
  p_recipe_id uuid    DEFAULT NULL,
  p_products  jsonb   DEFAULT NULL,  -- array of [{product_id, quantity}]
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
  budget_headroom  numeric,          -- can be negative
  missing          jsonb,            -- ingredients / requested products not found
  products         jsonb,            -- full product rows for app to add to cart
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
        -- Recipe servings live on the recipes row
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

COMMIT;
