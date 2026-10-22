-- Ensure checkout-related RLS policies exist and match the app contract.

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "orders_select_own" ON public.orders;
DROP POLICY IF EXISTS "orders_insert_own" ON public.orders;
DROP POLICY IF EXISTS "orders_update_own" ON public.orders;
DROP POLICY IF EXISTS "orders_delete_own" ON public.orders;

CREATE POLICY "orders_select_own" ON public.orders
    FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "orders_insert_own" ON public.orders
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "orders_update_own" ON public.orders
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "orders_delete_own" ON public.orders
    FOR DELETE
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "payments_select_own" ON public.payments;
DROP POLICY IF EXISTS "payments_insert_own" ON public.payments;
DROP POLICY IF EXISTS "payments_update_own" ON public.payments;
DROP POLICY IF EXISTS "payments_delete_own" ON public.payments;

CREATE POLICY "payments_select_own" ON public.payments
    FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "payments_insert_own" ON public.payments
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "payments_update_own" ON public.payments
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "payments_delete_own" ON public.payments
    FOR DELETE
    USING (auth.uid() = user_id);
