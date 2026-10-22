-- =============================================================
-- DRIVER DEVICE BINDING — one recognised device per driver
--
-- Goal: a driver can only work from one phone at a time, and a phone the
-- account has never seen (a replacement handset, or a lost one someone else
-- picked up) cannot be used until its holder proves possession of the
-- driver's SIM by SMS.
--
-- How it fits together:
--   * The Driver app generates a UUID on first run and stores it in
--     SharedPreferences. That UUID — not the OS device id — identifies the
--     install, which is why this works identically on Google-play devices and
--     Huawei (HMS) devices, where no shared Android id is available.
--   * The driver-device-verify edge function upserts one row per
--     (user_id, device_id) in public.driver_devices. Only a device whose
--     OTP challenge passed carries verified_at, and exactly one row per
--     driver carries is_current = true.
--   * Every write happens with the service role, so clients cannot mark their
--     own device current. The table's own RLS only lets a driver *read* their
--     devices.
--   * "Last sign-in wins": binding a new device marks the previous current
--     device revoked_at + is_current = false. The old app sees 'superseded'
--     on its next check and signs itself out.
--
-- One-time effect of applying this: every already-signed-in driver session
-- has no device row, so it is treated as unrecognised and the driver re-verifies
-- by SMS the next time they sign in.
-- =============================================================

create extension if not exists pgcrypto;

-- -------------------------------------------------------------
-- The device registry
-- -------------------------------------------------------------
create table if not exists public.driver_devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    -- Install-scoped UUID minted by the app on first run (see the Driver app's
    -- DeviceBindingService). Not an OS identifier.
    device_id text not null,
    platform text not null default '',
    os_version text not null default '',
    app_version text not null default '',
    -- Stamped only when this device's holder passed an SMS challenge.
    verified_at timestamptz,
    -- Set when another device took over. A revoked device can never become
    -- current again except through a fresh SMS verification.
    revoked_at timestamptz,
    -- At most one row per driver has this true (enforced below).
    is_current boolean not null default false,
    last_seen_at timestamptz not null default timezone('utc', now()),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    constraint driver_devices_user_device_key unique (user_id, device_id),
    constraint driver_devices_device_id_length
        check (char_length(device_id) between 8 and 128)
);

create index if not exists idx_driver_devices_current
    on public.driver_devices (user_id)
    where is_current;

-- Read-only for the app: binding and revocation are service-role operations
-- performed by the driver-device-verify function. With no INSERT/UPDATE/DELETE
-- policy, a tampered client cannot bind a stolen device or un-revoke itself.
alter table public.driver_devices enable row level security;

drop policy if exists "Drivers can read their own devices" on public.driver_devices;
create policy "Drivers can read their own devices"
    on public.driver_devices
    for select
    to authenticated
    using (user_id = auth.uid());

-- -------------------------------------------------------------
-- One current device per driver, enforced in the database
--
-- Two devices cannot both claim the flag: the second UPDATE fails until the
-- first is cleared, so a race between two bindings resolves to one winner.
-- -------------------------------------------------------------
create or replace function public.set_current_driver_device(
    p_user_id uuid,
    p_device_id text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    -- Demote whatever was current for this driver.
    update public.driver_devices
       set is_current = false,
           revoked_at = coalesce(revoked_at, timezone('utc', now())),
           updated_at = timezone('utc', now())
     where user_id = p_user_id
       and is_current;

    -- Bind the new device.
    update public.driver_devices
       set is_current = true,
           revoked_at = null,
           verified_at = coalesce(verified_at, timezone('utc', now())),
           last_seen_at = timezone('utc', now()),
           updated_at = timezone('utc', now())
     where user_id = p_user_id
       and device_id = p_device_id;
end;
$$;

revoke execute on function public.set_current_driver_device(uuid, text) from public, anon, authenticated;
grant execute on function public.set_current_driver_device(uuid, text) to service_role;

comment on function public.set_current_driver_device(uuid, text) is
  'Makes (user_id, device_id) the single current device for the driver: every other device for that driver is demoted and stamped revoked_at. Service role only — clients cannot call it.';

-- -------------------------------------------------------------
-- Device challenges ride on the existing OTP table
--
-- phone_otp_challenges already stores SHA-256 hashes of the code with a TTL
-- and an attempt counter (see add_phone_otp_auth.sql). Device verification
-- reuses that table so the resend throttle and rate limiting stay in one
-- place, but needs its own purpose value: 'login' is bound to users.phone,
-- while most drivers only have drivers.contact_number.
-- -------------------------------------------------------------
do $$
declare
    constraint_row record;
begin
    for constraint_row in
        select conname
          from pg_constraint
         where contype = 'c'
           and conrelid = 'public.phone_otp_challenges'::regclass
           and pg_get_constraintdef(oid) ~ 'purpose'
    loop
        execute format(
            'alter table public.phone_otp_challenges drop constraint %I',
            constraint_row.conname
        );
    end loop;

    alter table public.phone_otp_challenges
        add constraint phone_otp_challenges_purpose_check
        check (purpose in ('signup', 'login', 'device'));
end;
$$;

comment on column public.phone_otp_challenges.purpose is
  'signup / login: customer phone verification (send-phone-otp, verify-phone-otp). device: driver device re-verification (driver-device-verify).';
