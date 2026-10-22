-- =============================================
-- Migration: Add store_payouts table for payout requests
-- Created: 2026-05-07
-- Note: stores table already has individual bank columns (bank_name, bank_code, account_number, account_name, paystack_recipient_code)
-- =============================================

-- Create store_payouts table for tracking payout requests
-- bank_details stores a JSONB snapshot of the store's bank details at time of payout
CREATE TABLE IF NOT EXISTS public.store_payouts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    bank_details JSONB NOT NULL DEFAULT '{}'::jsonb,
    notes TEXT,
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create indexes for store_payouts
CREATE INDEX IF NOT EXISTS idx_store_payouts_store_id ON public.store_payouts(store_id);
CREATE INDEX IF NOT EXISTS idx_store_payouts_status ON public.store_payouts(status);
CREATE INDEX IF NOT EXISTS idx_store_payouts_created_at ON public.store_payouts(created_at DESC);

-- Enable Row Level Security on store_payouts
ALTER TABLE public.store_payouts ENABLE ROW LEVEL SECURITY;

-- RLS policies for store_payouts
CREATE POLICY "Store owners can view their own payouts" ON public.store_payouts
    FOR SELECT USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_payouts.store_id
        )
    );

CREATE POLICY "Store owners can insert their own payouts" ON public.store_payouts
    FOR INSERT WITH CHECK (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_payouts.store_id
        )
    );

CREATE POLICY "Store owners can update their own payouts" ON public.store_payouts
    FOR UPDATE USING (
        auth.uid() IN (
            SELECT owner_id FROM public.stores WHERE id = store_payouts.store_id
        )
    );
