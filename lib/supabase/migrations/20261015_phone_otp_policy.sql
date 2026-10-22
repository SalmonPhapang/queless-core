-- ============================================================================
-- Phone OTP policy: server-authoritative, with a local override for dev
-- ============================================================================
-- Moves the "is phone OTP confirmation required?" decision out of the app's
-- bundled `.env` (which a repackaged client can edit) and into the database,
-- where:
--
--   * every client reads the same value at startup (public.app_settings),
--   * only platform admins or the service role can change it,
--   * the value is actually *enforced* server-side: while it is on, a profile
--     that claims a phone number can only be created after that number passed
--     a verify-phone-otp challenge (see the trigger in section 5).
--
-- Reading the policy:
--   select phone_otp_verification_required from public.app_settings;
--
-- Flipping the policy (platform admin or service role):
--   update public.app_settings set phone_otp_verification_required = true;
--
-- This migration is idempotent, and it is seeded OFF so it does not change the
-- behaviour the apps shipped before it existed.

-- ---------------------------------------------------------------------------
-- 1. Canonical phone normalisation
-- ---------------------------------------------------------------------------
-- Mirrors normalizePhoneNumber() in the send-phone-otp / verify-phone-otp edge
-- functions, so a number typed on the client always compares equal to the
-- number stored on the challenge row.
create or replace function public.queless_normalize_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  v := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');

  if v = '' then
    return null;
  end if;

  if v like '00%' then
    v := '+' || substr(v, 3);
  end if;

  if left(v, 1) <> '+' then
    if left(v, 1) = '0' and length(v) = 10 then
      v := '+27' || substr(v, 2);
    else
      v := '+' || v;
    end if;
  end if;

  if v !~ '^\+\d{8,15}$' then
    return null;
  end if;

  return v;
end;
$$;

comment on function public.queless_normalize_phone(text) is
  'Normalises a phone number exactly like the send-phone-otp / verify-phone-otp edge functions do. Returns NULL when the input is not a usable number.';

-- ---------------------------------------------------------------------------
-- 2. The policy row: one row, readable by every client, writable by operators
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
    id boolean primary key default true,
    phone_otp_verification_required boolean not null default true,
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid,
    constraint app_settings_singleton check (id)
);

comment on table public.app_settings is
  'Single-row, server-authoritative application policy. Read by every client, written only by platform admins or the service role.';
comment on column public.app_settings.phone_otp_verification_required is
  'When true the client must complete a phone OTP challenge, and the server refuses a profile that claims an unverified phone number.';

-- Seeded OFF to match the current rollout decision. The fail-secure default
-- used by the helpers below is ON, so a missing row requires verification.
insert into public.app_settings (id, phone_otp_verification_required)
values (true, false)
on conflict (id) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists "App settings are readable by everyone" on public.app_settings;
create policy "App settings are readable by everyone"
  on public.app_settings
  for select
  to anon, authenticated
  using (true);

drop policy if exists "Platform admins can update app settings" on public.app_settings;
create policy "Platform admins can update app settings"
  on public.app_settings
  for update
  to authenticated
  using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- Stamp who changed the policy, and make it impossible to move the singleton
-- row to id = false (which would create a second, shadow policy row).
create or replace function public.touch_app_settings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.id := true;
  new.updated_at := timezone('utc', now());
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists touch_app_settings on public.app_settings;
create trigger touch_app_settings
  before update on public.app_settings
  for each row
  execute function public.touch_app_settings();

-- ---------------------------------------------------------------------------
-- 3. Provenance for phone verifications
-- ---------------------------------------------------------------------------
-- consumed_at alone cannot prove a successful verification: it is also stamped
-- when a challenge is exhausted or cancelled. verified_at is only ever set on a
-- correct code, by verify-phone-otp.
alter table public.phone_otp_challenges
  add column if not exists verified_at timestamptz;

comment on column public.phone_otp_challenges.verified_at is
  'Set only when the code was entered correctly. consumed_at is also stamped for exhausted challenges, so it cannot be used as proof of success.';

create index if not exists idx_phone_otp_challenges_verified_phone
  on public.phone_otp_challenges (phone, verified_at)
  where verified_at is not null;

-- ---------------------------------------------------------------------------
-- 4. Policy readers
-- ---------------------------------------------------------------------------
create or replace function public.phone_otp_verification_required()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select phone_otp_verification_required from public.app_settings where id),
    true
  );
$$;

comment on function public.phone_otp_verification_required() is
  'True when phone OTP confirmation is required. Fails secure: a missing app_settings row means required.';

-- p_phone must already be normalised with queless_normalize_phone().
create or replace function public.is_phone_otp_verified(
  p_phone text,
  p_purpose text default 'signup',
  p_window interval default interval '1 hour'
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.phone_otp_challenges c
     where c.purpose = p_purpose
       and c.verified_at is not null
       and c.verified_at > timezone('utc', now()) - p_window
       and c.phone is not null
       and (
         c.phone = p_phone
         or public.queless_normalize_phone(c.phone) = p_phone
       )
  );
$$;

comment on function public.is_phone_otp_verified(text, text, interval) is
  'True when p_phone passed a verified OTP challenge of the given purpose inside the window.';

create or replace function public.assert_phone_otp_verified(p_phone text)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text;
begin
  if not public.phone_otp_verification_required() then
    return;
  end if;

  v_phone := public.queless_normalize_phone(p_phone);

  -- No usable phone claimed, so there is nothing to verify. The driver app
  -- creates its public.users row without a phone; a customer profile without a
  -- phone cannot sign in anyway, because sign-in requires one.
  if v_phone is null then
    return;
  end if;

  if not public.is_phone_otp_verified(v_phone) then
    raise exception 'Phone verification is required before this account can be created. Please verify your number and try again.'
      using errcode = 'check_violation';
  end if;
end;
$$;

comment on function public.assert_phone_otp_verified(text) is
  'Raises when the policy requires phone OTP confirmation and the given phone has no recent verified challenge.';

-- ---------------------------------------------------------------------------
-- 5. Enforcement: a profile that claims a phone must have verified it
-- ---------------------------------------------------------------------------
create or replace function public.enforce_phone_otp_on_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Trusted server-side sessions: migrations, the SQL editor, pg_cron.
  --
  -- NOTE: this has to be session_user, not current_user. A SECURITY DEFINER
  -- function runs as its owner, so current_user is always 'postgres' inside it
  -- and using it here silently exempts every client.
  if session_user in ('postgres', 'supabase_admin', 'supabase_auth_admin') then
    return new;
  end if;

  -- Service-role API calls (admin tooling, edge functions) are not subject to
  -- the client policy. PostgREST connects as 'authenticator' and carries the
  -- effective role in the JWT claims.
  if coalesce(
       nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
       ''
     ) = 'service_role' then
    return new;
  end if;

  perform public.assert_phone_otp_verified(new.phone);
  return new;
end;
$$;

comment on function public.enforce_phone_otp_on_profile() is
  'BEFORE INSERT guard on public.users: refuses a profile whose phone number has not passed a recent OTP challenge while the policy is on. Trusted sessions (session_user = postgres/supabase_admin) and service-role API calls are exempt.';

drop trigger if exists enforce_phone_otp_on_profile on public.users;
create trigger enforce_phone_otp_on_profile
  before insert on public.users
  for each row
  execute function public.enforce_phone_otp_on_profile();

-- ---------------------------------------------------------------------------
-- 6. Least-privilege grants
-- ---------------------------------------------------------------------------
-- Supabase's default privileges grant EXECUTE on new functions in `public` to
-- anon, authenticated and service_role, so a bare `revoke ... from public` is
-- not enough: name those roles explicitly. Clients only need the policy flag and
-- the normaliser - the verification lookups stay server-side (the trigger runs
-- as the table owner) so a client cannot probe which numbers have been verified.
revoke execute on function public.phone_otp_verification_required() from public;
grant execute on function public.phone_otp_verification_required()
  to anon, authenticated, service_role;

revoke execute on function public.queless_normalize_phone(text) from public;
grant execute on function public.queless_normalize_phone(text)
  to anon, authenticated, service_role;

revoke execute on function public.is_phone_otp_verified(text, text, interval)
  from public, anon, authenticated;
grant execute on function public.is_phone_otp_verified(text, text, interval)
  to service_role;

revoke execute on function public.assert_phone_otp_verified(text)
  from public, anon, authenticated;
grant execute on function public.assert_phone_otp_verified(text) to service_role;

revoke execute on function public.enforce_phone_otp_on_profile()
  from public, anon, authenticated;
grant execute on function public.enforce_phone_otp_on_profile() to service_role;

-- ---------------------------------------------------------------------------
-- 7. Known limits (documented so the next reader does not assume otherwise)
-- ---------------------------------------------------------------------------
-- * Only INSERT into public.users is guarded. A phone *change* (edit profile)
--   still relies on the client gate; add an UPDATE branch if that matters.
-- * A client that omits the phone passes the trigger (the driver app needs
--   that), but the customer app requires a phone to sign in, so this is not a
--   viable bypass of phone verification.
-- * Sign-in OTP is enforced by the client, not the database: the auth session
--   itself is issued by Supabase Auth, which has no knowledge of this policy.
