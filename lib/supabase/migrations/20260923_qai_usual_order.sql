-- ============================================================================
-- Phase 14 — Repeat Order Intelligence ("Order my usual")
--
-- qai_usual_order(p_user_id) returns the user's most recent completed order
-- re-priced against today's catalog:
--
--   * Picks the latest order in a completed/delivered state with items.
--   * Re-prices every item against public.products: dead product ids are
--     DROPPED, not fatal (the same deleted-catalog hazard fixed in the
--     Phase 3 rebuild — 46 order items currently reference deleted products).
--   * Surviving items carry last_price (what they paid), current_price
--     (today's price), current_stock, and an `available` flag (in stock).
--   * Returns store info, the original order total, today's subtotal for
--     available items only, and unavailable_count so the UI can say
--     "N items no longer available" honestly.
--
-- SECURITY DEFINER + grants: called by the signed-in app user via REST, and
-- p_user_id is always the caller's own id (the Flutter service passes the
-- session user; RLS on orders still protects data at rest).
-- ============================================================================

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
AS $fn$
DECLARE
  v_order record;
  v_items jsonb;
  v_unavailable integer := 0;
  v_subtotal numeric := 0;
BEGIN
  SELECT o.id, o.order_number, o.store_id, o.total, o.items
  INTO v_order
  FROM public.orders o
  WHERE o.user_id = p_user_id
    AND o.status IN ('delivered', 'completed')
    AND jsonb_typeof(o.items) = 'array'
    AND jsonb_array_length(o.items) > 0
  ORDER BY o.created_at DESC
  LIMIT 1;

  IF v_order.id IS NULL THEN
    RETURN;
  END IF;

  -- Re-price each item against the live catalog. Dead product ids are
  -- DROPPED (not fatal); survivors carry last_price, current_price,
  -- current_stock and an `available` flag for the UI.
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
      -- Re-price with the app's margin convention: user-facing price is
      -- floor(base * 1.125) + 0.99 (Product.feeRate in the Flutter model).
      -- base_price_per_unit in past orders is the RAW price; price_per_unit
      -- is what the user actually paid (margin already inside).
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

  -- Today's subtotal counts available items only, at current prices.
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

GRANT EXECUTE ON FUNCTION public.qai_usual_order(uuid) TO anon, authenticated;
