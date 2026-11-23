-- Allow a signed-in customer to remove their own delivery instruments on
-- sign-out. The Edge Functions use the service role and are unaffected.

drop policy if exists "Users can delete their own tokens"
  on public.user_fcm_tokens;
create policy "Users can delete their own tokens"
  on public.user_fcm_tokens for delete
  using (auth.uid() = user_id);

drop policy if exists "Users can delete their own web push subscriptions"
  on public.web_push_subscriptions;
create policy "Users can delete their own web push subscriptions"
  on public.web_push_subscriptions for delete
  using (auth.uid() = user_id);
