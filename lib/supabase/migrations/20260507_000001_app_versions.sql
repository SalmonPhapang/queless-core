-- Create app_type enum
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_type') THEN
        CREATE TYPE app_type AS ENUM ('user', 'store', 'driver');
    END IF;
END $$;

-- Create app_versions table
CREATE TABLE IF NOT EXISTS public.app_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_name app_type NOT NULL,
    version TEXT NOT NULL,
    build_number INTEGER NOT NULL,
    min_build_number INTEGER DEFAULT 0,
    release_notes TEXT,
    download_url TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_force_update BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(app_name, build_number)
);

-- Enable RLS
ALTER TABLE public.app_versions ENABLE ROW LEVEL SECURITY;

-- Allow public read access to app_versions
CREATE POLICY "Allow public read access to app_versions" 
ON public.app_versions FOR SELECT 
TO public 
USING (is_active = true);
