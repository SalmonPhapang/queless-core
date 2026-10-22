ALTER TABLE public.products
  ALTER COLUMN volume DROP NOT NULL;

ALTER TABLE public.products
  ALTER COLUMN volume DROP DEFAULT;

UPDATE public.products
SET volume = NULL
WHERE volume IS NOT NULL AND btrim(volume) = '';

