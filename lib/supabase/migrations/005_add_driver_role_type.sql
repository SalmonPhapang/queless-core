-- =============================================
-- Add role_type column to drivers table
-- =============================================

ALTER TABLE public.drivers
ADD COLUMN IF NOT EXISTS role_type TEXT NOT NULL DEFAULT 'driver'
CHECK (role_type IN ('driver', 'admin'));
