-- ============================================================================
-- Device binding policy: server-authoritative, with a local override for dev
-- ============================================================================
-- Moves "is this phone allowed to hold the driver's session?" out of the app
-- and into the database, alongside the phone OTP policy:
--
--   select device_binding_required from public.app_settings;
--
--   update public.app_settings set device_binding_required = false;  -- off
--   update public.app_settings set device_binding_required = true;   -- on
--
-- Why it lives here:
--   * every client reads the same value at startup (app_settings is readable
--     by anon and authenticated — see 20261015_phone_otp_policy.sql),
--   * only platform admins or the service role can change it; the existing
--     app_settings policies already cover this column, and the
--     touch_app_settings trigger still stamps updated_at / updated_by,
--   * the server *enforces* it: while the flag is off, driver-device-verify
--     answers 'verified' for every install, so a patched client cannot be the
--     only thing standing between a driver and the gate.
--
-- Seeded ON, which is the behaviour that 20261016_000001_driver_device_binding.sql
-- shipped. Turning it OFF is a testing switch — a handset that cannot receive
-- the driver's SMS, or a device farm running many accounts on one phone — and
-- it removes the binding gate for EVERY driver on the project. A debug/profile
-- build can instead disable binding locally with `ENABLE_DEVICE_BINDING=false`
-- in the Driver app's `.env`, which release builds ignore and which never
-- touches this row.
--
-- Idempotent: safe to re-run.

alter table public.app_settings
  add column if not exists device_binding_required boolean not null default true;

comment on column public.app_settings.device_binding_required is
  'When true a driver session is only kept on the account''s bound device (public.driver_devices), and an unrecognised phone must pass an SMS challenge before it becomes current. When false, driver-device-verify reports every install as verified: a testing switch, not a production one.';
