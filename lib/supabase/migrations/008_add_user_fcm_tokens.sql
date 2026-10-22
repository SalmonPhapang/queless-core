-- =============================================
-- Add user_fcm_tokens table
-- =============================================

-- Create table if not exists
CREATE TABLE IF NOT EXISTS public.user_fcm_tokens (
    user_id UUID NOT NULL,
    token TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT user_fcm_tokens_pkey PRIMARY KEY (user_id, token),
    CONSTRAINT user_fcm_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
) TABLESPACE pg_default;

-- Enable RLS
ALTER TABLE public.user_fcm_tokens ENABLE ROW LEVEL SECURITY;

-- Policy: Users can manage their own tokens
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_fcm_tokens'
      AND policyname = 'users_can_manage_own_tokens'
  ) THEN
    CREATE POLICY users_can_manage_own_tokens
    ON public.user_fcm_tokens
    FOR ALL
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
  END IF;
END
$$;
