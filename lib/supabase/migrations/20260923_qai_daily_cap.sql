-- Per-user daily message cap support for the ai-chat edge function.
--
-- The function counts each user's messages for the current SAST day from
-- ai_messages. That needs (a) the owner on each row — previously only
-- conversation_id was stored — and (b) an index that makes the count cheap.

ALTER TABLE public.ai_messages
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ai_messages_user_role_created
  ON public.ai_messages (user_id, role, created_at);
