-- =============================================
-- Correct live tracking to use driver_assignments as the source of truth
-- =============================================

CREATE OR REPLACE FUNCTION get_driver_for_order(p_order_id UUID)
RETURNS TABLE(
    id UUID,
    order_id UUID,
    driver_id UUID,
    status TEXT,
    notes TEXT,
    current_lat DOUBLE PRECISION,
    current_lng DOUBLE PRECISION,
    last_location_update TIMESTAMPTZ,
    location_accuracy DOUBLE PRECISION,
    location_speed DOUBLE PRECISION,
    location_heading DOUBLE PRECISION,
    accepted_at TIMESTAMPTZ,
    picked_up_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    driver_table_id UUID,
    driver_user_id UUID,
    driver_full_name TEXT,
    driver_contact_number TEXT,
    driver_image_url TEXT,
    driver_vehicle_make TEXT,
    driver_vehicle_model TEXT,
    driver_vehicle_color TEXT,
    driver_vehicle_plate TEXT,
    driver_rating NUMERIC,
    driver_vehicle_type TEXT,
    driver_is_verified BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        da.id,
        da.order_id,
        da.driver_id,
        da.status,
        da.notes,
        da.current_lat,
        da.current_lng,
        da.last_location_update,
        da.location_accuracy,
        da.location_speed,
        da.location_heading,
        da.accepted_at,
        da.picked_up_at,
        da.delivered_at,
        da.cancelled_at,
        da.created_at,
        da.updated_at,
        d.id,
        d.user_id,
        d.full_name,
        d.contact_number,
        d.image_url,
        d.vehicle_make,
        d.vehicle_model,
        d.vehicle_color,
        d.vehicle_plate,
        d.rating,
        d.vehicle_type,
        d.is_verified
    FROM public.driver_assignments da
    JOIN public.drivers d ON d.user_id = da.driver_id
    WHERE da.order_id = p_order_id
    ORDER BY da.updated_at DESC, da.created_at DESC
    LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION get_drivers_for_orders(p_order_ids UUID[])
RETURNS TABLE(
    id UUID,
    order_id UUID,
    driver_id UUID,
    status TEXT,
    notes TEXT,
    current_lat DOUBLE PRECISION,
    current_lng DOUBLE PRECISION,
    last_location_update TIMESTAMPTZ,
    location_accuracy DOUBLE PRECISION,
    location_speed DOUBLE PRECISION,
    location_heading DOUBLE PRECISION,
    accepted_at TIMESTAMPTZ,
    picked_up_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    driver_table_id UUID,
    driver_user_id UUID,
    driver_full_name TEXT,
    driver_contact_number TEXT,
    driver_image_url TEXT,
    driver_vehicle_make TEXT,
    driver_vehicle_model TEXT,
    driver_vehicle_color TEXT,
    driver_vehicle_plate TEXT,
    driver_rating NUMERIC,
    driver_vehicle_type TEXT,
    driver_is_verified BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        da.id,
        da.order_id,
        da.driver_id,
        da.status,
        da.notes,
        da.current_lat,
        da.current_lng,
        da.last_location_update,
        da.location_accuracy,
        da.location_speed,
        da.location_heading,
        da.accepted_at,
        da.picked_up_at,
        da.delivered_at,
        da.cancelled_at,
        da.created_at,
        da.updated_at,
        d.id,
        d.user_id,
        d.full_name,
        d.contact_number,
        d.image_url,
        d.vehicle_make,
        d.vehicle_model,
        d.vehicle_color,
        d.vehicle_plate,
        d.rating,
        d.vehicle_type,
        d.is_verified
    FROM public.driver_assignments da
    JOIN public.drivers d ON d.user_id = da.driver_id
    WHERE da.order_id = ANY(p_order_ids)
    ORDER BY da.updated_at DESC, da.created_at DESC;
END;
$$;

ALTER TABLE public.orders
DROP COLUMN IF EXISTS driver_name,
DROP COLUMN IF EXISTS driver_phone,
DROP COLUMN IF EXISTS driver_location,
DROP COLUMN IF EXISTS estimated_delivery_time;
