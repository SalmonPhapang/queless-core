-- =============================================
-- Add live driver tracking fields and tighten order update policy
-- =============================================

ALTER TABLE public.driver_assignments
ADD COLUMN IF NOT EXISTS current_lat DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS current_lng DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS last_location_update TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS location_accuracy DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS location_speed DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS location_heading DOUBLE PRECISION;

CREATE INDEX IF NOT EXISTS idx_driver_assignments_last_location_update
ON public.driver_assignments(last_location_update DESC);

DROP POLICY IF EXISTS drivers_can_update_order_status ON public.orders;

CREATE POLICY drivers_can_update_order_status
ON public.orders
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.driver_assignments da
    WHERE da.order_id = orders.id
      AND da.driver_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.driver_assignments da
    WHERE da.order_id = orders.id
      AND da.driver_id = auth.uid()
  )
);
