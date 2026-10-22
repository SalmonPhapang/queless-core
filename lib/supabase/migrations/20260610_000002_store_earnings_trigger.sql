-- =============================================
-- Migration: Add store_earnings unique constraint + trigger
-- Created: 2026-06-10
-- Purpose:
--   - Adds a UNIQUE constraint on (order_id) so all paths
--     (trigger, OrderService, StorePayoutService._syncEarnings)
--     can safely coexist without duplicating records.
--   - Creates a database trigger that automatically inserts a
--     store_earnings record whenever an order's status changes
--     to 'delivered' or 'collected'.  This covers every path:
--       • Store owner marks delivered/collected in store app
--       • Driver marks delivered in driver app
--       • Admin panel, direct SQL, etc.
-- =============================================

-- =============================================
-- 1. UNIQUE constraint on order_id
--    Prevents duplicate earnings for the same order
--    regardless of which path inserts the record.
-- =============================================
ALTER TABLE public.store_earnings
    ADD CONSTRAINT store_earnings_order_id_unique
    UNIQUE (order_id);

-- =============================================
-- 2. Trigger function
--    SECURITY DEFINER so it runs as the table owner,
--    bypassing RLS (neither the store owner nor the
--    driver has INSERT rights on store_earnings).
-- =============================================
CREATE OR REPLACE FUNCTION public.insert_store_earnings_on_order_completion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_store_earning  DECIMAL(10, 2);
BEGIN
    -- Only proceed when status transitions to delivered or collected
    IF OLD.status IS DISTINCT FROM NEW.status
       AND NEW.status IN ('delivered', 'collected')
    THEN
        -- Skip orders not linked to a store (e.g. direct user orders)
        IF NEW.store_id IS NULL THEN
            RETURN NEW;
        END IF;

        -- Skip if a store_earnings record already exists
        IF EXISTS (SELECT 1 FROM public.store_earnings WHERE order_id = NEW.id) THEN
            RETURN NEW;
        END IF;

        -- Calculate the store's share
        -- The store gets the sum of (quantity * base_price_per_unit) from the items JSONB array.
        SELECT COALESCE(SUM((item->>'quantity')::numeric * (item->>'base_price_per_unit')::numeric), 0)
        INTO v_store_earning
        FROM jsonb_array_elements(NEW.items) AS item;

        -- Floor at R0 (store never owes for an order)
        IF v_store_earning < 0 THEN
            v_store_earning := 0;
        END IF;

        INSERT INTO public.store_earnings (store_id, order_id, amount, status)
        VALUES (NEW.store_id, NEW.id, v_store_earning, 'earned')
        ON CONFLICT (order_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

-- =============================================
-- 3. The trigger
--    Fires AFTER UPDATE of the status column
--    so the insert sees the new status.
-- =============================================
DROP TRIGGER IF EXISTS trg_insert_store_earnings ON public.orders;

CREATE TRIGGER trg_insert_store_earnings
    AFTER UPDATE OF status ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION public.insert_store_earnings_on_order_completion();
