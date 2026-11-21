-- ============================================================================
-- Ask Q support upgrade — in-app tickets + authoritative FAQ content
--
-- Scope (v1):
--   * order status, delivery, payment and cancellation questions
--   * honest human handoff through an in-app support ticket
--   * one shared support-article source for Ask Q and the FAQ screen
--   * no automated refunds, complaints or order mutations
--
-- All customer identity comes from auth.uid(). Client-supplied user ids are
-- never accepted.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Support tickets
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.support_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  order_id uuid NULL REFERENCES public.orders(id) ON DELETE SET NULL,
  conversation_id uuid NULL REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
  category text NOT NULL CHECK (
    category IN ('order_status', 'delivery', 'payment', 'cancellation', 'other')
  ),
  status text NOT NULL DEFAULT 'open' CHECK (
    status IN ('open', 'pending', 'resolved', 'closed')
  ),
  subject text NOT NULL,
  description text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz NULL
);

CREATE TABLE IF NOT EXISTS public.support_ticket_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  author_role text NOT NULL CHECK (
    author_role IN ('customer', 'assistant', 'support_agent', 'system')
  ),
  body text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS support_tickets_user_created_idx
  ON public.support_tickets (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS support_tickets_status_idx
  ON public.support_tickets (status, created_at DESC);
CREATE INDEX IF NOT EXISTS support_ticket_messages_ticket_created_idx
  ON public.support_ticket_messages (ticket_id, created_at DESC);

ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_ticket_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Customers read own support tickets" ON public.support_tickets;
CREATE POLICY "Customers read own support tickets"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Direct inserts are not granted; qai_create_support_ticket is the only path,
-- so ownership and order/conversation checks cannot be bypassed.
DROP POLICY IF EXISTS "Customers create own support tickets" ON public.support_tickets;
CREATE POLICY "Customers create own support tickets"
  ON public.support_tickets FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Customers read messages for own support tickets" ON public.support_ticket_messages;
CREATE POLICY "Customers read messages for own support tickets"
  ON public.support_ticket_messages FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.support_tickets t
      WHERE t.id = ticket_id AND t.user_id = auth.uid()
    )
  );

GRANT SELECT ON public.support_tickets TO authenticated;
GRANT SELECT ON public.support_ticket_messages TO authenticated;
GRANT ALL ON public.support_tickets TO service_role;
GRANT ALL ON public.support_ticket_messages TO service_role;

COMMENT ON TABLE public.support_tickets IS
  'Customer-visible handoff from Ask Q. Customers may read only their own tickets; status changes are service-role/admin only.';

-- ----------------------------------------------------------------------------
-- 2. Create-ticket RPC (SECURITY DEFINER, but identity is always auth.uid())
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.qai_create_support_ticket(
  p_order_id uuid,
  p_conversation_id uuid,
  p_category text,
  p_subject text,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS public.support_tickets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_ticket public.support_tickets;
  v_category text := lower(btrim(coalesce(p_category, '')));
  v_subject text := btrim(coalesce(p_subject, ''));
  v_description text := btrim(coalesce(p_description, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF v_category NOT IN ('order_status', 'delivery', 'payment', 'cancellation', 'other') THEN
    RAISE EXCEPTION 'invalid_support_category';
  END IF;
  IF char_length(v_subject) < 3 OR char_length(v_subject) > 200 THEN
    RAISE EXCEPTION 'invalid_support_subject';
  END IF;
  IF char_length(v_description) < 3 OR char_length(v_description) > 4000 THEN
    RAISE EXCEPTION 'invalid_support_description';
  END IF;

  IF p_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND o.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'order_not_owned';
  END IF;

  IF p_conversation_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.ai_conversations c
    WHERE c.id = p_conversation_id AND c.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'conversation_not_owned';
  END IF;

  INSERT INTO public.support_tickets (
    user_id, order_id, conversation_id, category, subject, description, metadata
  )
  VALUES (
    v_uid, p_order_id, p_conversation_id, v_category, v_subject, v_description,
    coalesce(p_metadata, '{}'::jsonb)
  )
  RETURNING * INTO v_ticket;

  INSERT INTO public.support_ticket_messages (ticket_id, author_role, body, metadata)
  VALUES (
    v_ticket.id,
    'customer',
    v_description,
    jsonb_build_object('source', 'ask_q', 'category', v_category)
  );

  RETURN v_ticket;
END;
$fn$;

REVOKE ALL ON FUNCTION public.qai_create_support_ticket(uuid, uuid, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qai_create_support_ticket(uuid, uuid, text, text, text, jsonb) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Authoritative support content (FAQ / help centre)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.support_articles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  category text NOT NULL CHECK (
    category IN ('order_status', 'delivery', 'payment', 'cancellation', 'general')
  ),
  question text NOT NULL,
  answer_md text NOT NULL,
  source text NOT NULL DEFAULT 'Queless help centre',
  status text NOT NULL DEFAULT 'published' CHECK (
    status IN ('draft', 'published', 'archived')
  ),
  effective_from timestamptz NULL,
  effective_to timestamptz NULL,
  searchable_text text NULL,
  embedding vector(768) NULL,
  embedding_model text NULL,
  embedded_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS support_articles_published_idx
  ON public.support_articles (status, category, updated_at DESC);

ALTER TABLE public.support_articles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users read published support articles" ON public.support_articles;
CREATE POLICY "Authenticated users read published support articles"
  ON public.support_articles FOR SELECT
  TO authenticated
  USING (
    status = 'published'
    AND (effective_from IS NULL OR effective_from <= now())
    AND (effective_to IS NULL OR effective_to > now())
  );

GRANT SELECT ON public.support_articles TO authenticated;
GRANT ALL ON public.support_articles TO service_role;

COMMENT ON TABLE public.support_articles IS
  'Single source of truth for FAQ/support answers used by Ask Q and the FAQ screen.';

INSERT INTO public.support_articles (slug, category, question, answer_md) VALUES
  (
    'delivery-time',
    'delivery',
    'How long does delivery take?',
    'Most deliveries are completed within 30-60 minutes, depending on your location and the store''s preparation time. You can follow live progress from the Orders tab.'
  ),
  (
    'delivery-hours',
    'delivery',
    'What are the delivery hours?',
    'Delivery hours vary by store and follow South African liquor laws. Alcohol delivery is only available during legal trading hours, and the driver will check ID on arrival.'
  ),
  (
    'minimum-order',
    'general',
    'Is there a minimum order amount?',
    'Most stores have a minimum order amount of R150 before delivery. The exact amount is shown on the store page before you check out.'
  ),
  (
    'track-order',
    'order_status',
    'How do I track my order?',
    'Open the Orders tab and select the order to see live status and driver location. You can also tap "Track my order" in Ask Q.'
  ),
  (
    'missing-or-damaged',
    'delivery',
    'What if my items are missing or damaged?',
    'Tell Q which order it was and choose Delivery. Q will open an in-app support ticket with the order details, and a human teammate will review what happened. Q cannot promise a refund or replacement itself.'
  ),
  (
    'payment-not-going-through',
    'payment',
    'My payment failed. Was I charged?',
    'A failed payment means the payment did not go through and no money should have been taken. If you see a deduction on your statement, ask Q to open a payment ticket so a teammate can check the receipt.'
  ),
  (
    'cancel-order',
    'cancellation',
    'How do I cancel my order?',
    'Unpaid orders can be cancelled from the payment screen before payment is completed. For paid or already-preparing orders, ask Q to open a cancellation ticket so a teammate can check what is possible.'
  ),
  (
    'age-verification',
    'delivery',
    'Do I need to show my ID?',
    'Yes. South African law requires the recipient to be 18 or older for alcohol. Drivers ask for a valid South African ID or passport on delivery.'
  ),
  (
    'refund-request',
    'payment',
    'How do I request a refund?',
    'Refund decisions are handled by a human teammate. Ask Q to open a support ticket with your order number and what went wrong; Q will not promise a refund or start one automatically.'
  )
ON CONFLICT (slug) DO UPDATE SET
  category = EXCLUDED.category,
  question = EXCLUDED.question,
  answer_md = EXCLUDED.answer_md,
  source = EXCLUDED.source,
  status = 'published',
  effective_to = NULL,
  updated_at = now();

UPDATE public.support_articles
   SET searchable_text = question || E'\n' || answer_md
 WHERE searchable_text IS NULL;

-- ----------------------------------------------------------------------------
-- 4. FAQ retrieval RPC for the authenticated ai-chat Edge Function
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.qai_search_support_articles(
  p_query text,
  p_limit integer DEFAULT 4
)
RETURNS TABLE (
  article_id uuid,
  slug text,
  category text,
  question text,
  answer text,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  SELECT a.id, a.slug, a.category, a.question, a.answer_md, a.updated_at
  FROM public.support_articles a
  WHERE a.status = 'published'
    AND (a.effective_from IS NULL OR a.effective_from <= now())
    AND (a.effective_to IS NULL OR a.effective_to > now())
    AND (
      coalesce(btrim(p_query), '') = ''
      OR a.question ILIKE '%' || p_query || '%'
      OR a.answer_md ILIKE '%' || p_query || '%'
      OR to_tsvector('simple', a.question || ' ' || a.answer_md)
         @@ plainto_tsquery('simple', p_query)
    )
  ORDER BY a.updated_at DESC
  LIMIT least(greatest(coalesce(p_limit, 4), 1), 8);
$fn$;

REVOKE ALL ON FUNCTION public.qai_search_support_articles(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qai_search_support_articles(text, integer) TO authenticated, service_role;
