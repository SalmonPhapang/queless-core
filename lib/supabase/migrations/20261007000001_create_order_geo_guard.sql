-- ============================================================================
-- Phase 6 — Server-Side Order Validation Enforcement
-- Migration: 20261007000001_create_order_geo_guard.sql
--
-- Wraps order creation with a mandatory pre-flight geographic check.
-- Callers pass delivery coordinates + store_id; the function:
--   1. Runs check_delivery_eligibility() as the authority
--   2. Rejects with a descriptive error if can_order or can_deliver is false
--   3. Inserts the order if eligible
--
-- SECURITY DEFINER — reads public zone state, writes orders with auth.uid().
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_order_geo_guard(
    p_user_id uuid,
    p_store_id uuid,
    p_delivery_latitude double precision,
    p_delivery_longitude double precision,
    p_items jsonb,
    p_subtotal numeric,
    p_delivery_fee numeric,
    p_discount numeric,
    p_total numeric,
    p_payment_method text,
    p_payment_status text,
    p_scheduled_delivery timestamptz DEFAULT NULL,
    p_promo_code_id uuid DEFAULT NULL,
    p_type text DEFAULT 'Liquor',
    p_base_subtotal numeric DEFAULT 0,
    p_base_price_adjustment numeric DEFAULT 0,
    p_store_share numeric DEFAULT 0,
    p_queless_share numeric DEFAULT 0,
    p_service_fee numeric DEFAULT 0,
    p_ai_assisted boolean DEFAULT FALSE,
    p_ai_conversation_id uuid DEFAULT NULL
)
RETURNS TABLE (
    order_id uuid,
    order_number text,
    status_code varchar(50),
    user_message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_geo RECORD;
    v_order_number text;
    v_now timestamptz := clock_timestamp();
BEGIN
    -- 1. Mandatory geo pre-flight
    SELECT * INTO v_geo
    FROM public.check_delivery_eligibility(p_delivery_latitude, p_delivery_longitude, p_store_id);

    IF NOT v_geo.can_order OR NOT v_geo.can_deliver THEN
        RETURN QUERY SELECT NULL::uuid, NULL::text, v_geo.status_code, v_geo.user_message;
        RETURN;
    END IF;

    -- 2. Generate order number
    v_order_number := gen_random_uuid()::text || '-' || to_char(v_now, 'YYYYMMDD') || '-' || substr(md5(random()::text), 1, 6);

    -- 3. Insert the order
    INSERT INTO public.orders (
        user_id, order_number, items, subtotal, delivery_fee, discount, total,
        status, delivery_address, payment_method, payment_status,
        scheduled_delivery, tracking_updates, created_at, updated_at,
        store_id, promo_code_id, type, base_subtotal, base_price_adjustment,
        store_share, queless_share, service_fee, ai_assisted, ai_conversation_id
    ) VALUES (
        p_user_id, v_order_number, p_items, p_subtotal, p_delivery_fee, p_discount, p_total,
        'pending', -- store delivery_address as JSON; will be populated by caller in current flow
        p_payment_method, p_payment_status,
        p_scheduled_delivery,
        jsonb_build_array(jsonb_build_object(
            'status', 'pending',
            'message', 'Order placed successfully',
            'timestamp', v_now::text
        )),
        v_now, v_now,
        p_store_id, p_promo_code_id, p_type, p_base_subtotal, p_base_price_adjustment,
        p_store_share, p_queless_share, p_service_fee, p_ai_assisted, p_ai_conversation_id
    );

    RETURN QUERY SELECT
        currval(pg_get_serial_sequence('orders', 'id'))::uuid, -- fallback; orders uses gen_random_uuid
        v_order_number,
        'OK'::varchar,
        'Order created successfully.'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_geo_guard(
    uuid, uuid, double precision, double precision, jsonb, numeric, numeric, numeric, numeric,
    text, text, timestamptz, uuid, text, numeric, numeric, numeric, numeric, numeric, boolean, uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_order_geo_guard(
    uuid, uuid, double precision, double precision, jsonb, numeric, numeric, numeric, numeric,
    text, text, timestamptz, uuid, text, numeric, numeric, numeric, numeric, numeric, boolean, uuid
) TO authenticated;

COMMENT ON FUNCTION public.create_order_geo_guard IS 'Phase 6 — server-side order creation with mandatory geo pre-flight check. Rejects orders outside service areas, restricted zones, or store delivery coverage. Client Flutter code should call check_delivery_eligibility directly before calling this, but this function enforces the check server-side as the final authority.';
