-- Cross-platform customer notifications:
--   * React native builds register Expo Push tokens in user_fcm_tokens
--   * the browser PWA registers PushSubscriptions in web_push_subscriptions
--
-- Native Flutter FCM topics and the existing HMS provider value are unchanged.

create table if not exists public.web_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  expiration_time bigint,
  user_agent text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists web_push_subscriptions_endpoint_key
  on public.web_push_subscriptions (endpoint);

create index if not exists web_push_subscriptions_user_id_idx
  on public.web_push_subscriptions (user_id);

alter table public.web_push_subscriptions enable row level security;

drop policy if exists "Users can view their own web push subscriptions"
  on public.web_push_subscriptions;
create policy "Users can view their own web push subscriptions"
  on public.web_push_subscriptions for select
  using (auth.uid() = user_id);

drop policy if exists "Users can insert their own web push subscriptions"
  on public.web_push_subscriptions;
create policy "Users can insert their own web push subscriptions"
  on public.web_push_subscriptions for insert
  with check (auth.uid() = user_id);

drop policy if exists "Users can update their own web push subscriptions"
  on public.web_push_subscriptions;
create policy "Users can update their own web push subscriptions"
  on public.web_push_subscriptions for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can delete their own web push subscriptions"
  on public.web_push_subscriptions;
create policy "Users can delete their own web push subscriptions"
  on public.web_push_subscriptions for delete
  using (auth.uid() = user_id);

-- user_fcm_tokens.provider originally allowed only fcm/hms. Add expo without
-- dropping the constraint, so an unexpected value is still rejected.
alter table public.user_fcm_tokens
  drop constraint if exists user_fcm_tokens_provider_check;

alter table public.user_fcm_tokens
  add constraint user_fcm_tokens_provider_check
  check (provider in ('fcm', 'hms', 'expo'));
