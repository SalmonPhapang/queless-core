-- Add bank details to drivers table
ALTER TABLE public.drivers 
ADD COLUMN IF NOT EXISTS bank_details JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Create driver payouts table
CREATE TABLE IF NOT EXISTS public.driver_payouts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    amount DECIMAL(10, 2) NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'rejected')),
    bank_details JSONB NOT NULL,
    notes TEXT,
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create driver payments table (tracks earnings per order)
CREATE TABLE IF NOT EXISTS public.driver_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    payout_id UUID REFERENCES public.driver_payouts(id) ON DELETE SET NULL,
    amount DECIMAL(10, 2) NOT NULL,
    status TEXT NOT NULL DEFAULT 'earned' CHECK (status IN ('earned', 'pending_payout', 'paid')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(order_id) -- One payment per order
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_driver_payouts_driver_id ON public.driver_payouts(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_payouts_status ON public.driver_payouts(status);
CREATE INDEX IF NOT EXISTS idx_driver_payments_driver_id ON public.driver_payments(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_payments_order_id ON public.driver_payments(order_id);
CREATE INDEX IF NOT EXISTS idx_driver_payments_payout_id ON public.driver_payments(payout_id);
CREATE INDEX IF NOT EXISTS idx_driver_payments_status ON public.driver_payments(status);

-- Enable RLS
ALTER TABLE public.driver_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.driver_payments ENABLE ROW LEVEL SECURITY;

-- RLS Policies for driver_payouts
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'driver_payouts'
      AND policyname = 'drivers_can_view_own_payouts'
  ) THEN
    CREATE POLICY drivers_can_view_own_payouts
    ON public.driver_payouts
    FOR SELECT
    TO authenticated
    USING (driver_id = auth.uid());
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'driver_payouts'
      AND policyname = 'drivers_can_create_payout_requests'
  ) THEN
    CREATE POLICY drivers_can_create_payout_requests
    ON public.driver_payouts
    FOR INSERT
    TO authenticated
    WITH CHECK (driver_id = auth.uid());
  END IF;
END
$$;

-- RLS Policies for driver_payments
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'driver_payments'
      AND policyname = 'drivers_can_view_own_payments'
  ) THEN
    CREATE POLICY drivers_can_view_own_payments
    ON public.driver_payments
    FOR SELECT
    TO authenticated
    USING (driver_id = auth.uid());
  END IF;
END
$$;
