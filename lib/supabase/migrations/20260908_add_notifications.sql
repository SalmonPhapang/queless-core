-- ============================================================
-- NOTIFICATIONS HISTORY
-- Durable, per-user record of every push we send. Even when a
-- device is offline (or the push is never displayed), the row
-- persists so the in-app inbox can show what the user missed.
--
-- Written by edge functions (service role) and read/updated by
-- the user app (RLS-scoped to the owning user).
-- ============================================================

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  type text not null default 'order',
  title text not null default '',
  body text not null default '',
  order_id text,
  order_number text,
  status text,
  data jsonb not null default '{}'::jsonb,
  is_read boolean not null default false,
  created_at timestamptz not null default timezone('utc'::text, now()),
  updated_at timestamptz not null default timezone('utc'::text, now())
);

create index if not exists idx_notifications_user_created
  on public.notifications (user_id, created_at desc);

-- Partial index for fast unread-badge counts.
create index if not exists idx_notifications_user_unread
  on public.notifications (user_id)
  where is_read = false;

-- Row Level Security: users only ever see/touch their own rows.
alter table public.notifications enable row level security;

create policy "Users can view their own notifications"
  on public.notifications for select
  using (auth.uid() = user_id);

create policy "Users can update their own notifications"
  on public.notifications for update
  using (auth.uid() = user_id);

create policy "Users can insert their own notifications"
  on public.notifications for insert
  with check (auth.uid() = user_id);
