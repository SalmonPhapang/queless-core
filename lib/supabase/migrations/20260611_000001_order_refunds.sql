-- =============================================
-- Migration: Add refunds table
-- Created: 2026-06-11
-- Purpose:
--   - Track refunds for rejected or cancelled orders.
-- =============================================

CREATE TABLE IF NOT EXISTS public.order_refunds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    transaction_id TEXT, -- Paystack transaction ID being refunded
    refund_id TEXT,      -- Paystack refund ID
    amount DECIMAL(10, 2) NOT NULL,
    reason TEXT,
    status TEXT NOT NULL DEFAULT 'pending', -- pending, completed, failed
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.order_refunds ENABLE ROW LEVEL SECURITY;

-- Add indexes
CREATE INDEX IF NOT EXISTS idx_order_refunds_order_id ON public.order_refunds(order_id);
CREATE INDEX IF NOT EXISTS idx_order_refunds_status ON public.order_refunds(status);

-- RLS Policies
-- Allow store owners to see refunds for their orders
CREATE POLICY "Store owners can view refunds for their orders"
ON public.order_refunds
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        JOIN public.stores s ON o.store_id = s.id
        WHERE o.id = public.order_refunds.order_id
        AND s.owner_id = auth.uid()
    )
);

-- Allow users to see their own refunds
CREATE POLICY "Users can view their own refunds"
ON public.order_refunds
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = public.order_refunds.order_id
        AND o.user_id = auth.uid()
    )
);

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_refunds_updated_at
    BEFORE UPDATE ON public.order_refunds
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();
