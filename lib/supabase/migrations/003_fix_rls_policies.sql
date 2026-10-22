-- Fix RLS Policies for driver_payments
-- Add INSERT policy for drivers to record their earnings
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'driver_payments'
      AND policyname = 'drivers_can_insert_own_payments'
  ) THEN
    CREATE POLICY drivers_can_insert_own_payments
    ON public.driver_payments
    FOR INSERT
    TO authenticated
    WITH CHECK (driver_id = auth.uid());
  END IF;
END
$$;

-- Add UPDATE policy for drivers to link payments to payouts
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'driver_payments'
      AND policyname = 'drivers_can_update_own_payments'
  ) THEN
    CREATE POLICY drivers_can_update_own_payments
    ON public.driver_payments
    FOR UPDATE
    TO authenticated
    USING (driver_id = auth.uid())
    WITH CHECK (driver_id = auth.uid());
  END IF;
END
$$;

-- Fix RLS Policies for drivers table (ensure bank_details can be updated)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'drivers'
      AND policyname = 'drivers_can_update_own_bank_details'
  ) THEN
    CREATE POLICY drivers_can_update_own_bank_details
    ON public.drivers
    FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
  END IF;
END
$$;
