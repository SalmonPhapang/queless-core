-- =============================================
-- Migration: Create store_earnings table
-- Created: 2026-06-10
-- Purpose: Track the store's calculated earnings per completed order,
--          following the same pattern as driver_payments in the driver app.
--          Each delivered/collected order gets a row here with status 'earned'.
--          When a payout is requested, the row's status is set to 'pending_payout'
--          and linked to the payout_id, preventing double-counting.
-- =============================================

CREATE TABLE IF NOT EXISTS public.store_earnings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'earned',
    payout_id UUID REFERENCES public.store_payouts(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_store_earnings_store_id ON public.store_earnings(store_id);
CREATE INDEX IF NOT EXISTS idx_store_earnings_order_id ON public.store_earnings(order_id);
CREATE INDEX IF NOT EXISTS idx_store_earnings_status ON public.store_earnings(status);
CREATE INDEX IF NOT EXISTS idx_store_earnings_payout_id ON public.store_earnings(payout_id);

-- Enable Row Level Security
ALTER TABLE public.store_earnings ENABLE ROW LEVEL SECURITY;

-- RLS policies: store owners can manage their own earnings
CREATE POLICY "Store owners can view their own earnings" ON public.store_earnings
    FOR SELECT USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_earnings.store_id
        )
    );

CREATE POLICY "Store owners can insert their own earnings" ON public.store_earnings
    FOR INSERT WITH CHECK (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_earnings.store_id
        )
    );

CREATE POLICY "Store owners can update their own earnings" ON public.store_earnings
    FOR UPDATE USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_earnings.store_id
        )
    );
