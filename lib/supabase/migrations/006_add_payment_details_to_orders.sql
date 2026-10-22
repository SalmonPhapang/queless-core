-- =============================================
-- Add payment details columns to orders table
-- =============================================

ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS amount_received NUMERIC,
ADD COLUMN IF NOT EXISTS receipt_number TEXT;
