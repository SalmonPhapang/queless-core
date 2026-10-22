-- Add paystack_recipient_code to drivers table
ALTER TABLE public.drivers
ADD COLUMN IF NOT EXISTS paystack_recipient_code TEXT;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_drivers_paystack_recipient_code ON public.drivers(paystack_recipient_code);
