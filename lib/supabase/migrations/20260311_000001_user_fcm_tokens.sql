CREATE TABLE IF NOT EXISTS public.user_fcm_tokens (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.user_fcm_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own fcm tokens" ON public.user_fcm_tokens;
DROP POLICY IF EXISTS "Users can insert their own fcm tokens" ON public.user_fcm_tokens;
DROP POLICY IF EXISTS "Users can update their own fcm tokens" ON public.user_fcm_tokens;
DROP POLICY IF EXISTS "Users can delete their own fcm tokens" ON public.user_fcm_tokens;

CREATE POLICY "Users can view their own fcm tokens" ON public.user_fcm_tokens
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own fcm tokens" ON public.user_fcm_tokens
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own fcm tokens" ON public.user_fcm_tokens
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own fcm tokens" ON public.user_fcm_tokens
  FOR DELETE USING (auth.uid() = user_id);

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS fcm_token TEXT;

