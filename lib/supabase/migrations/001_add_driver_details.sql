-- Add full_name, contact_number, id_number, and is_verified to the drivers table
ALTER TABLE public.drivers
ADD COLUMN IF NOT EXISTS full_name TEXT NOT NULL DEFAULT '',
ADD COLUMN IF NOT EXISTS contact_number TEXT NOT NULL DEFAULT '',
ADD COLUMN IF NOT EXISTS id_number TEXT NOT NULL DEFAULT '',
ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE;
