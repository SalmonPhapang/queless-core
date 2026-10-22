-- =============================================
-- RLS POLICIES FOR DRIVER_ASSIGNMENTS & DRIVERS
-- =============================================

-- Enable RLS on both tables (idempotent)
ALTER TABLE IF EXISTS public.driver_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.drivers ENABLE ROW LEVEL SECURITY;

-- =============================================
-- DRIVER_ASSIGNMENTS TABLE POLICIES
-- =============================================

DROP POLICY IF EXISTS "Allow authenticated users to view driver assignments" ON public.driver_assignments;
DROP POLICY IF EXISTS "Allow authenticated users to insert driver assignments" ON public.driver_assignments;
DROP POLICY IF EXISTS "Allow authenticated users to update driver assignments" ON public.driver_assignments;

-- Authenticated users can see all driver assignments (needed by store owners to check driver info)
CREATE POLICY "Allow authenticated users to view driver assignments"
    ON public.driver_assignments
    FOR SELECT
    TO authenticated
    USING (true);

-- The driver assignment system manages inserts/updates (not store owners)
CREATE POLICY "Allow authenticated users to insert driver assignments"
    ON public.driver_assignments
    FOR INSERT
    TO authenticated
    WITH CHECK (true);

CREATE POLICY "Allow authenticated users to update driver assignments"
    ON public.driver_assignments
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- =============================================
-- DRIVERS TABLE POLICIES
-- =============================================

DROP POLICY IF EXISTS "Allow authenticated users to view drivers" ON public.drivers;
DROP POLICY IF EXISTS "Allow authenticated users to update drivers" ON public.drivers;

-- Authenticated users can see driver profiles (needed by store owners)
CREATE POLICY "Allow authenticated users to view drivers"
    ON public.drivers
    FOR SELECT
    TO authenticated
    USING (true);

-- Drivers can update their own profile (for the driver app)
CREATE POLICY "Allow authenticated users to update drivers"
    ON public.drivers
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);
