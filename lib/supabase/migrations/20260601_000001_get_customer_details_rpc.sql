-- =============================================
-- Migration: Add RPC function to fetch customer details
-- Created: 2026-06-01
-- Purpose: Allow store owners to fetch customer names and phone numbers
--          by user_id, bypassing RLS (SECURITY DEFINER)
-- =============================================

-- RPC function to fetch customer details by user IDs
-- Uses SECURITY DEFINER to bypass RLS on the users table
CREATE OR REPLACE FUNCTION get_customer_details(customer_ids UUID[])
RETURNS TABLE(id UUID, full_name TEXT, phone TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.full_name, u.phone
    FROM public.users u
    WHERE u.id = ANY(customer_ids);
END;
$$;

-- Also add a single-user version for convenience
CREATE OR REPLACE FUNCTION get_customer_detail(customer_id UUID)
RETURNS TABLE(id UUID, full_name TEXT, phone TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.full_name, u.phone
    FROM public.users u
    WHERE u.id = customer_id;
END;
$$;
