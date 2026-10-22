-- =============================================
-- Migration: Add Store Owner RLS Policies for Orders
-- Created: 2026-05-21
-- Purpose: Allow store owners to view and manage orders for their stores
-- =============================================

-- 1. Allow store owners to SELECT orders for their stores
CREATE POLICY "store_owners_select_orders" ON public.orders
    FOR SELECT
    TO authenticated
    USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = orders.store_id
        )
    );

-- 2. Allow store owners to UPDATE order status for their stores
CREATE POLICY "store_owners_update_orders" ON public.orders
    FOR UPDATE
    TO authenticated
    USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = orders.store_id
        )
    )
    WITH CHECK (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = orders.store_id
        )
    );
