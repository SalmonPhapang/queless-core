-- Add store_id and cancel_reason to orders
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES public.stores(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_orders_store_id ON public.orders(store_id);

