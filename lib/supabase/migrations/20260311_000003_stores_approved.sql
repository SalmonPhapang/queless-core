ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS is_approved BOOLEAN NOT NULL DEFAULT false;

UPDATE public.stores
SET is_approved = false
WHERE is_approved IS NULL;

