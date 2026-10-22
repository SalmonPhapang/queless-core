create extension if not exists pgcrypto;

create table if not exists public.password_reset_challenges (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    channel text not null check (channel in ('sms', 'email')),
    contact text not null,
    code_hash text not null,
    attempt_count integer not null default 0,
    max_attempts integer not null default 5,
    expires_at timestamptz not null,
    consumed_at timestamptz,
    reset_token_hash text,
    reset_token_expires_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_password_reset_challenges_lookup
    on public.password_reset_challenges (contact, channel, created_at desc);

create index if not exists idx_password_reset_challenges_active
    on public.password_reset_challenges (expires_at)
    where consumed_at is null;

create index if not exists idx_password_reset_challenges_token
    on public.password_reset_challenges (reset_token_expires_at)
    where reset_token_hash is not null and consumed_at is null;

alter table public.password_reset_challenges enable row level security;

drop policy if exists "No public access to password_reset_challenges" on public.password_reset_challenges;
create policy "No public access to password_reset_challenges"
    on public.password_reset_challenges
    for all
    using (false)
    with check (false);
