-- =============================================
-- Fix driver_assignments foreign key constraint
-- =============================================

-- First, check what the current constraint is
DO $$
BEGIN
    RAISE NOTICE 'Checking current foreign key constraints on driver_assignments';
END $$;

-- Drop the existing constraint if it's referencing public.users instead of auth.users
ALTER TABLE public.driver_assignments
DROP CONSTRAINT IF EXISTS driver_assignments_driver_id_fkey;

-- Re-add the constraint to reference auth.users.id
ALTER TABLE public.driver_assignments
ADD CONSTRAINT driver_assignments_driver_id_fkey
FOREIGN KEY (driver_id)
REFERENCES auth.users(id)
ON DELETE SET NULL;

DO $$
BEGIN
    RAISE NOTICE 'Successfully fixed driver_assignments foreign key constraint!';
END $$;
