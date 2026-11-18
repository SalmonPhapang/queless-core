-- Fleet-wide edge-call telemetry for the Driver & Store apps.
-- Written by queless_core's edgeTelemetrySink: failures are always recorded,
-- successes optional. Queryable from the admin app (service role) for fleet
-- edge-health visibility.

create table if not exists public.edge_call_events (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default timezone('utc', now()),
    app text not null,
    function_name text not null,
    success boolean not null default false,
    latency_ms integer,
    status integer,
    error text,
    user_id uuid references auth.users (id) on delete set null
);

create index if not exists idx_edge_call_events_recent
    on public.edge_call_events (created_at desc);

create index if not exists idx_edge_call_events_function
    on public.edge_call_events (function_name, success);

alter table public.edge_call_events enable row level security;

-- Telemetry rows are non-sensitive (function name, latency, success), so any
-- user may insert (tied to their own user_id when logged in); the admin
-- backend reads the fleet table via service role.
create policy "Anyone can record edge call telemetry"
    on public.edge_call_events for insert
    to anon, authenticated
    with check (auth.uid() = user_id or user_id is null);

create policy "Service role reads edge call telemetry"
    on public.edge_call_events for select
    to service_role
    using (true);
