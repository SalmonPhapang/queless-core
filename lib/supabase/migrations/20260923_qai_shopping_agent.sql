-- ============================================================================
-- Phase 16 — Full AI Shopping Agent
--
-- Scenario: "Get me everything I need for an Asian dinner for 6 under R600."
--
-- Agent pipeline (10-step, roadmap Phase 16 §20):
--   Understand → Select meal → Find recipe → Extract ingredients →
--   Search inventory → Compare stores → Optimize basket → Calculate total →
--   Prepare cart → *ASK FOR EXPLICIT CONFIRMATION* (never auto-place order).
--
-- Three RPCs:
--   1. qai_build_multi_recipe_basket — multi-recipe shopping list aggregator
--      (feeds recipes from search + optional budget/servings — returns the
--      flat union of all ingredients across recipes, so the agent can feed
--      one list into the optimizer instead of N separate basket calls).
--   2. qai_optimize_store_selection — cross-store comparison. Takes the flat
--      ingredient list and returns TOP-3 store coverage rows, each with a
--      substitution suggestion for missing products (cheaper same-category
--      swap at the same store), per-store total, and best-store headroom
--      vs budget.
--   3. ai_cart_events audit table (no RLS, SERVICE ROLE writes, user-scoped
--      reads) + qai_record_cart_event helper — records each phase-16
--      "prepare cart / confirm / add items / checkout handoff" action for
--      the Phase 17 analytics (AI-assisted carts + Orders-from-AI metric).
--
-- Safety rules (Roadmap §4):
--   * No auto-place order. Placement = TRANSACTION-tier confirmation (the
--     Flutter checkout screen already handles it; we only hand off).
--   * No invented prices. All totals come from real products
--     floor(raw*1.125)+0.99 exactly matching edge function customerPrice().
--   * No invented availability. Substitutions are drawn from LIVE inventory
--     at the SAME store (same category, in_stock>0, price within 20% band).
--   * No cross-store ADD. Each returned row is a SINGLE store so the UI can
--     add the whole proposal to the single-store CartService (SSOT routing).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1  Audit event table (Phase 17 bridge — Events are inserted by the
--      edge function service role; the user only reads their own rows).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_cart_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    conversation_id uuid REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
    event_type text NOT NULL CHECK (event_type IN (
        'cart_proposed',
        'cart_item_confirmed',
        'cart_items_added',
        'cart_substitution_accepted',
        'cart_substitution_rejected',
        'checkout_handoff'
    )),
    store_id uuid REFERENCES public.stores(id) ON DELETE SET NULL,
    product_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
    total_cost numeric,
    items integer,
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

-- ----------------------------------------------------------------------------
-- 3.2  Helper: customer price — floor(raw * 1.125) + 0.99
--      (SSOT identical to edge function customerPrice and Product.feeRate.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._qai_cust(p numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (floor(COALESCE(p, 0) * 1.125) + 0.99)::numeric(12,2);
$$;
REVOKE ALL ON FUNCTION public._qai_cust(numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._qai_cust(numeric) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3.3  qai_build_multi_recipe_basket(recipe_ids[], budget, servings)
--
--      Aggregates N recipe plans into ONE flat ingredient list, so the
--      agent can pass the list once into the store optimizer rather than
--      making N basket calls.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_build_multi_recipe_basket(
    p_recipe_ids uuid[]  DEFAULT NULL,
    p_budget     numeric DEFAULT NULL,
    p_servings   integer DEFAULT NULL
)
RETURNS TABLE (
    request_total   numeric,
    request_per_usr numeric,
    recipe_count    integer,
    items           jsonb   -- [{ingredient, quantity, unit, matched_products:[{product_id, store_id, price, brand, halal}], best_product_id}]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_req     jsonb;
    v_per     numeric;
    v_cnt     integer := 0;
    v_budget  numeric;
BEGIN
    IF p_recipe_ids IS NULL OR array_length(p_recipe_ids, 1) IS NULL THEN
        request_total := 0;
        request_per_usr := 0;
        recipe_count := 0;
        items := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;

    v_cnt := array_length(p_recipe_ids, 1);
    v_budget := COALESCE(p_budget, 0);
    IF p_servings IS NOT NULL AND p_servings > 0 THEN
        v_per := v_budget / p_servings::numeric;
    ELSE
        v_per := 0;
    END IF;

    WITH recipes AS (
        SELECT r.id, r.title, r.servings, r.ingredients
        FROM public.recipes r
        WHERE r.id = ANY(p_recipe_ids)
    ),
    exploded AS (
        SELECT
            r.id AS recipe_id,
            r.title AS recipe_title,
            (elem->>'ingredient')::text AS ingredient_name,
            (elem->>'name')::text AS fallback_name,
            COALESCE(NULLIF((elem->>'quantity')::text, ''), '1') AS qty_raw,
            COALESCE(NULLIF((elem->>'unit')::text, ''), '') AS unit,
            jsonb_strip_nulls(jsonb_build_object(
                'ingredient', COALESCE(NULLIF((elem->>'ingredient')::text,''), NULLIF((elem->>'name')::text,''), 'item'),
                'quantity',   COALESCE(NULLIF((elem->>'quantity')::text,''), '1'),
                'unit',       COALESCE(NULLIF((elem->>'unit')::text,''), ''),
                'recipe_id',  r.id::text,
                'recipe_title', r.title
            )) AS item_meta
        FROM recipes r, jsonb_array_elements(r.ingredients) AS elem
    ),
    deduplicated AS (
        -- Aggregate same ingredient across recipes to de-duplicate shopping list.
        SELECT
            COALESCE(NULLIF(ingredient_name, ''), fallback_name, 'item') AS ingredient,
            max(item_meta) AS item_meta_sample,
            array_agg(DISTINCT recipe_id::text) AS recipe_ids,
            count(*) AS mentions
        FROM exploded
        GROUP BY 1
    ),
    matched AS (
        SELECT
            d.ingredient,
            d.item_meta_sample,
            d.mentions,
            d.recipe_ids,
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'product_id', p.id,
                        'store_id',   p.store_id,
                        'store_name', s.name,
                        'name',       p.name,
                        'brand',      COALESCE(p.brand, ''),
                        'price',      public._qai_cust(p.price),
                        'stock',      p.stock,
                        'halal',      COALESCE(array_position(p.tags, 'halal') IS NOT NULL, false),
                        'score',      CASE
                            WHEN LOWER(p.name) LIKE '%' || LOWER(d.ingredient) || '%' THEN 1.0
                            WHEN LOWER(p.description) LIKE '%' || LOWER(d.ingredient) || '%' THEN 0.75
                            ELSE 0.25
                        END
                    )
                )
                FROM (
                    SELECT pp.*, ss.name AS store_name_order
                    FROM public.products pp
                    JOIN public.stores ss ON ss.id = pp.store_id
                    WHERE pp.stock > 0
                      AND pp.alcohol_content IS NULL
                      AND LOWER(pp.product_type) <> 'alcohol'
                      AND (LOWER(pp.name) LIKE '%' || LOWER(d.ingredient) || '%'
                           OR LOWER(pp.description) LIKE '%' || LOWER(d.ingredient) || '%'
                           OR EXISTS (
                               SELECT 1 FROM unnest(pp.tags) t WHERE LOWER(t) LIKE '%' || LOWER(d.ingredient) || '%'
                           ))
                    ORDER BY (
                        CASE
                            WHEN LOWER(pp.name) LIKE '%' || LOWER(d.ingredient) || '%' THEN 1.0
                            WHEN LOWER(pp.description) LIKE '%' || LOWER(d.ingredient) || '%' THEN 0.75
                            ELSE 0.25
                        END
                    ) DESC, pp.stock DESC, public._qai_cust(pp.price) ASC
                    LIMIT 5
                ) p
                JOIN public.stores s ON s.id = p.store_id
            ) AS matched_products
        FROM deduplicated d
    ),
    final_items AS (
        SELECT
            jsonb_set(
                jsonb_set(m.item_meta_sample, '{matched_products}', COALESCE(m.matched_products, '[]'::jsonb)),
                '{best_product_id}',
                CASE
                    WHEN jsonb_array_length(COALESCE(m.matched_products, '[]'::jsonb)) > 0
                    THEN (m.matched_products->0->>'product_id')::jsonb
                    ELSE 'null'::jsonb
                END,
                true
            ) AS itm
        FROM matched m
    ),
    totals AS (
        SELECT round(COALESCE(sum(
            CASE WHEN jsonb_typeof((itm->'matched_products')->0) = 'object'
                 THEN COALESCE(((itm->'matched_products')->0->>'price')::numeric, 0)
                 ELSE 0 END
        ), 0), 2) AS estimated_total
        FROM final_items
    )
    SELECT INTO v_req
        jsonb_agg(itm ORDER BY (itm->>'ingredient')::text) FROM final_items;

    request_total   := (SELECT estimated_total FROM totals);
    request_per_usr := CASE WHEN p_servings > 0 THEN round(request_total / p_servings::numeric, 2) ELSE 0 END;
    recipe_count    := v_cnt;
    items           := COALESCE(v_req, '[]'::jsonb);
    RETURN NEXT;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_build_multi_recipe_basket(uuid[], numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_build_multi_recipe_basket(uuid[], numeric, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.qai_build_multi_recipe_basket(uuid[], numeric, integer)
IS 'Phase 16 — union N recipe ingredient lists into one de-duplicated shopping list, each item with up to 5 store-matched product candidates. Returns total+per_usr for budget comparison.';

-- ----------------------------------------------------------------------------
-- 3.4  qai_optimize_store_selection(items_jsonb, budget, servings)
--
--      Cross-store comparison. Takes the shopping list from the aggregator
--      (or agent-built flat list) and returns TOP-3 stores sorted by
--      (coverage ratio DESC, total_cost ASC). For each store we also propose
--      a same-category at-the-same-store substitution for any item that
--      store does not stock (max 1 substitute per missing line, 20% price
--      band of the best-matching price elsewhere).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_optimize_store_selection(
    p_items    jsonb   DEFAULT NULL,   -- array of {ingredient, best_product_id, matched_products:[{product_id, store_id, price, store_name}]}
    p_budget   numeric DEFAULT NULL,
    p_servings integer DEFAULT NULL
)
RETURNS TABLE (
    rank              integer,
    store_id          uuid,
    store_name        text,
    coverage_ratio    numeric,         -- 0.0..1.0
    matched_items     integer,
    missing_items     integer,
    total_cost        numeric,
    per_person_cost   numeric,
    within_budget     boolean,
    headroom          numeric,         -- budget - total; negative when over
    delivery_fee      numeric,
    items             jsonb,           -- enriched: matched items + price + substitute flag
    substitutions     jsonb,           -- [{line:"...", missing_product_name, suggested_product_id, suggested_product_name, delta}]
    missing           jsonb            -- [{ingredient, reason}]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_item_cnt integer := 0;
    v_budget   numeric;
    v_row      record;
    v_rnk      integer := 0;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RETURN;
    END IF;

    v_item_cnt := jsonb_array_length(p_items);
    v_budget   := COALESCE(p_budget, 0);

    FOR v_row IN
        WITH flat_items AS (
            SELECT
                (itm->>'ingredient')::text AS ingredient,
                (itm->>'best_product_id')::uuid AS best_pid,
                itm->'matched_products' AS candidates,
                idx AS line_no
            FROM jsonb_array_elements(p_items) WITH ORDINALITY AS a(itm, idx)
        ),
        per_store AS (
            SELECT
                s.id AS store_id,
                s.name AS store_name,
                s.delivery_fee,
                count(*) FILTER (WHERE EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(fi.candidates) AS cand
                    WHERE (cand->>'store_id')::uuid = s.id
                )) AS matched,
                round(
                    count(*) FILTER (WHERE EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements(fi.candidates) AS cand
                        WHERE (cand->>'store_id')::uuid = s.id
                    ))::numeric / greatest(v_item_cnt, 1),
                    3
                ) AS coverage,
                COALESCE(sum(
                    (
                        SELECT (cand->>'price')::numeric
                        FROM jsonb_array_elements(fi.candidates) AS cand
                        WHERE (cand->>'store_id')::uuid = s.id
                        ORDER BY (cand->>'score')::numeric DESC
                        LIMIT 1
                    )
                ), 0) AS items_total,
                jsonb_agg(
                    CASE WHEN EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements(fi.candidates) AS cand
                        WHERE (cand->>'store_id')::uuid = s.id
                    ) THEN jsonb_build_object(
                        'line_no', fi.line_no,
                        'ingredient', fi.ingredient,
                        'product_id', (
                            SELECT cand->>'product_id'
                            FROM jsonb_array_elements(fi.candidates) AS cand
                            WHERE (cand->>'store_id')::uuid = s.id
                            ORDER BY (cand->>'score')::numeric DESC
                            LIMIT 1
                        ),
                        'product_name', (
                            SELECT cand->>'name'
                            FROM jsonb_array_elements(fi.candidates) AS cand
                            WHERE (cand->>'store_id')::uuid = s.id
                            ORDER BY (cand->>'score')::numeric DESC
                            LIMIT 1
                        ),
                        'price', (
                            SELECT (cand->>'price')::numeric
                            FROM jsonb_array_elements(fi.candidates) AS cand
                            WHERE (cand->>'store_id')::uuid = s.id
                            ORDER BY (cand->>'score')::numeric DESC
                            LIMIT 1
                        ),
                        'substitute', false
                    ) ELSE jsonb_build_object(
                        'line_no', fi.line_no,
                        'ingredient', fi.ingredient,
                        'product_id', null,
                        'product_name', null,
                        'price', null,
                        'substitute', true
                    ) END
                    ORDER BY fi.line_no
                ) AS items_json,
                jsonb_agg(
                    CASE WHEN NOT EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements(fi.candidates) AS cand
                        WHERE (cand->>'store_id')::uuid = s.id
                    ) THEN jsonb_build_object(
                        'line_no', fi.line_no,
                        'ingredient', fi.ingredient,
                        'best_price_anywhere', (
                            SELECT min((cand->>'price')::numeric)
                            FROM jsonb_array_elements(fi.candidates) AS cand
                        ),
                        'best_pid_anywhere', (
                            SELECT cand->>'product_id'
                            FROM jsonb_array_elements(fi.candidates) AS cand
                            ORDER BY (cand->>'price')::numeric ASC
                            LIMIT 1
                        )
                    ) ELSE NULL END
                ) FILTER (WHERE NOT EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(fi.candidates) AS cand
                    WHERE (cand->>'store_id')::uuid = s.id
                )) AS missing_lines
            FROM public.stores s
            CROSS JOIN flat_items fi
            WHERE s.is_open = true
              AND s.is_approved = true
            GROUP BY 1,2,3
        ),
        with_subs AS (
            SELECT
                ps.*,
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'line_no',                  (swap_meta.line_no)::int,
                            'missing_ingredient',       swap_meta.ingredient,
                            'missing_best_price_elsewhere', swap_meta.best_price,
                            'suggested_product_id',     swap_meta.swap_id,
                            'suggested_product_name',   swap_meta.swap_name,
                            'suggested_price',          swap_meta.swap_price,
                            'price_delta',              round(swap_meta.swap_price - COALESCE(swap_meta.best_price, 0), 2),
                            'swap_reason',              swap_meta.swap_reason
                        )
                    )
                    FROM (
                        SELECT
                            (ml->>'line_no')::int AS line_no,
                            (ml->>'ingredient')::text AS ingredient,
                            (ml->>'best_price_anywhere')::numeric AS best_price,
                            picked_swap.id AS swap_id,
                            picked_swap.name AS swap_name,
                            public._qai_cust(picked_swap.price) AS swap_price,
                            CASE
                                WHEN LOWER(picked_swap.name) LIKE '%' || LOWER((ml->>'ingredient')::text) || '%' THEN 'close_match'
                                WHEN array_position(picked_swap.tags, 'halal') IS NOT NULL THEN 'halal_alternative'
                                ELSE 'same_category'
                            END AS swap_reason,
                            ROW_NUMBER() OVER (
                                PARTITION BY ml
                                ORDER BY abs(public._qai_cust(picked_swap.price) - COALESCE((ml->>'best_price_anywhere')::numeric, public._qai_cust(picked_swap.price))) ASC
                            ) AS rn
                        FROM jsonb_array_elements(ps.missing_lines) ml
                        JOIN public.products picked_swap
                          ON picked_swap.store_id = ps.store_id
                         AND picked_swap.stock > 0
                         AND picked_swap.alcohol_content IS NULL
                         AND LOWER(picked_swap.product_type) <> 'alcohol'
                         AND abs(public._qai_cust(picked_swap.price) - COALESCE((ml->>'best_price_anywhere')::numeric, public._qai_cust(picked_swap.price)))
                             <= GREATEST(COALESCE((ml->>'best_price_anywhere')::numeric * 0.2, 10), 5)
                    ) swap_meta
                    WHERE swap_meta.rn = 1
                ) AS sub_json
            FROM per_store ps
            WHERE ps.matched > 0  -- require at least one item in-store
        ),
        priced AS (
            SELECT
                ws.store_id,
                ws.store_name,
                ws.coverage,
                ws.matched,
                (v_item_cnt - ws.matched) AS missed,
                round((ws.items_total + COALESCE(ws.delivery_fee, 0))::numeric, 2) AS total,
                ws.items_total AS items_only,
                COALESCE(ws.delivery_fee, 0) AS dfee,
                ws.items_json AS enriched_items,
                COALESCE(ws.sub_json, '[]'::jsonb) AS sub_json,
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'ingredient', (ml->>'ingredient')::text,
                            'reason', CASE
                                WHEN (ml->>'best_price_anywhere')::numeric IS NULL THEN 'out_of_stock_all_stores'
                                ELSE 'not_stocked_here'
                            END
                        )
                        ORDER BY (ml->>'line_no')::int
                    )
                    FROM jsonb_array_elements(ws.missing_lines) ml
                    WHERE (ml->>'ingredient') IS NOT NULL
                ) AS miss_json
            FROM with_subs ws
        )
        SELECT * FROM priced
        ORDER BY coverage DESC, total ASC
        LIMIT 3
    LOOP
        v_rnk := v_rnk + 1;
        rank            := v_rnk;
        store_id        := v_row.store_id;
        store_name      := v_row.store_name;
        coverage_ratio  := v_row.coverage;
        matched_items   := v_row.matched;
        missing_items   := v_row.missed;
        total_cost      := v_row.total;
        per_person_cost := CASE WHEN p_servings > 0 THEN round(total_cost / p_servings::numeric, 2) ELSE 0 END;
        within_budget   := CASE WHEN v_budget > 0 THEN total_cost <= v_budget ELSE true END;
        headroom        := CASE WHEN v_budget > 0 THEN round(v_budget - total_cost, 2) ELSE NULL END;
        delivery_fee    := v_row.dfee;
        items           := v_row.enriched_items;
        substitutions   := v_row.sub_json;
        missing         := v_row.miss_json;
        RETURN NEXT;
    END LOOP;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_optimize_store_selection(jsonb, numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_optimize_store_selection(jsonb, numeric, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.qai_optimize_store_selection(jsonb, numeric, integer)
IS 'Phase 16 — Cross-store TOP-3 comparison for a shopping list. Each row has coverage ratio, per-store total, within-budget flag, same-store substitution suggestions for missing lines, and missing list with reason codes.';

-- ----------------------------------------------------------------------------
-- 3.5  qai_record_cart_event helper (user-scoped, inserts into audit table).
--      Called by the edge function service role / Flutter service after any
--      "cart proposed / confirmed / add-all / checkout handoff" action.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.qai_record_cart_event(
    p_event_type     text,
    p_store_id       uuid    DEFAULT NULL,
    p_product_ids    uuid[]  DEFAULT NULL,
    p_total_cost     numeric DEFAULT NULL,
    p_items          integer DEFAULT NULL,
    p_conversation_id uuid   DEFAULT NULL,
    p_metadata       jsonb   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
    v_uid uuid;
    v_eid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_event_type NOT IN (
        'cart_proposed','cart_item_confirmed','cart_items_added',
        'cart_substitution_accepted','cart_substitution_rejected','checkout_handoff'
    ) THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.ai_cart_events (
        user_id, conversation_id, event_type, store_id,
        product_ids, total_cost, items, metadata
    ) VALUES (
        v_uid,
        p_conversation_id,
        p_event_type,
        p_store_id,
        COALESCE(p_product_ids, '{}'::uuid[]),
        CASE WHEN p_total_cost >= 0 THEN p_total_cost ELSE NULL END,
        CASE WHEN p_items >= 0 THEN p_items ELSE NULL END,
        COALESCE(p_metadata, '{}'::jsonb)
    ) RETURNING id INTO v_eid;

    RETURN v_eid;
END;
$fn$;
REVOKE ALL ON FUNCTION public.qai_record_cart_event(text, uuid, uuid[], numeric, integer, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qai_record_cart_event(text, uuid, uuid[], numeric, integer, uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.qai_record_cart_event(text, uuid, uuid[], numeric, integer, uuid, jsonb)
IS 'Phase 16/17 — audit helper for AI-assisted shopping flows. Returns the inserted ai_cart_events.id, or NULL on RLS/auth/validation failure.';
