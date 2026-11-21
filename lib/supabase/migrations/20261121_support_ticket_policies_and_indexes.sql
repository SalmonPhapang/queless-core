-- Follow-up to 20261121_support_tickets_and_faq.sql:
--   * cover the new support_tickets foreign keys
--   * avoid re-evaluating auth.uid() per row in the new RLS policies
--
-- No behaviour changes: ticket inserts still go through qai_create_support_ticket,
-- and customers can still read only their own tickets and messages.

CREATE INDEX IF NOT EXISTS support_tickets_order_id_idx
  ON public.support_tickets (order_id);

CREATE INDEX IF NOT EXISTS support_tickets_conversation_id_idx
  ON public.support_tickets (conversation_id);

DROP POLICY IF EXISTS "Customers read own support tickets" ON public.support_tickets;
CREATE POLICY "Customers read own support tickets"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Customers create own support tickets" ON public.support_tickets;
CREATE POLICY "Customers create own support tickets"
  ON public.support_tickets FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Customers read messages for own support tickets" ON public.support_ticket_messages;
CREATE POLICY "Customers read messages for own support tickets"
  ON public.support_ticket_messages FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.support_tickets t
      WHERE t.id = ticket_id AND t.user_id = (SELECT auth.uid())
    )
  );
