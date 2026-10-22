-- =============================================
-- Migration: Add RPC functions to fetch driver details for orders
-- Created: 2026-06-03
-- Purpose: Allow store owners to view driver details (name, contact, vehicle)
--          on order details screen via a single JOIN query
-- Uses SECURITY DEFINER to bypass RLS on the drivers table
-- =============================================

-- Single-order RPC: Returns driver assignment + driver details for one order
CREATE OR REPLACE FUNCTION get_driver_for_order(p_order_id UUID)
RETURNS TABLE(
    -- driver_assignments columns
    id UUID,
    order_id UUID,
    driver_id UUID,
    status TEXT,
    notes TEXT,
    accepted_at TIMESTAMPTZ,
    picked_up_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    -- drivers columns (prefixed with driver_)
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
    ORDER BY da.created_at DESC
    LIMIT 1;
END;
$$;

-- Batch RPC: Returns driver assignment + driver details for multiple orders
-- Consistent with the get_customer_details pattern (accepts UUID[])
CREATE OR REPLACE FUNCTION get_drivers_for_orders(p_order_ids UUID[])
RETURNS TABLE(
    -- driver_assignments columns
    id UUID,
    order_id UUID,
    driver_id UUID,
    status TEXT,
    notes TEXT,
    accepted_at TIMESTAMPTZ,
    picked_up_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    -- drivers columns (prefixed with driver_)
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
    ORDER BY da.created_at DESC;
END;
$$;
