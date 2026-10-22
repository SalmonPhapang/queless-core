create extension if not exists pgcrypto;

create table if not exists public.phone_otp_challenges (
    id uuid primary key default gen_random_uuid(),
    phone text not null,
    purpose text not null check (purpose in ('signup', 'login')),
    code_hash text not null,
    requested_by_email text,
    user_id uuid,
    attempt_count integer not null default 0,
    max_attempts integer not null default 5,
    expires_at timestamptz not null,
    consumed_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_phone_otp_challenges_lookup
    on public.phone_otp_challenges (phone, purpose, created_at desc);

create index if not exists idx_phone_otp_challenges_active
    on public.phone_otp_challenges (expires_at)
    where consumed_at is null;

alter table public.phone_otp_challenges enable row level security;
