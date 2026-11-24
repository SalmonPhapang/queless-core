-- ============================================================================
-- Keep the two driver-location writes consistent.
--
-- The driver app writes a GPS fix to both public.driver_locations (used by
-- nearby_eligible_drivers for dispatch eligibility) and the per-assignment
-- columns public.driver_assignments.current_lat/current_lng (used by customer
-- and store tracking). If one write fails or races, dispatch can see a driver
-- as offline even though the app is publishing live positions.
--
-- This small AFTER trigger mirrors assignment location writes into
-- driver_locations, using the existing eight-column schema (driver_id +
-- current_lat/current_lng/last_location_update/accuracy/speed/heading). It
-- never creates a second location system and never overwrites a newer fix.
-- ============================================================================

create or replace function public.trg_mirror_assignment_location()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_at timestamptz := coalesce(NEW.last_location_update, timezone('utc', now()));
begin
    if NEW.driver_id is null or NEW.current_lat is null or NEW.current_lng is null then
        return NEW;
    end if;

    insert into public.driver_locations (
        driver_id,
        current_lat,
        current_lng,
        last_location_update,
        location_accuracy,
        location_speed,
        location_heading
    )
    values (
        NEW.driver_id,
        NEW.current_lat,
        NEW.current_lng,
        v_at,
        NEW.location_accuracy,
        NEW.location_speed,
        NEW.location_heading
    )
    on conflict (driver_id) do update
       set current_lat = excluded.current_lat,
           current_lng = excluded.current_lng,
           last_location_update = excluded.last_location_update,
           location_accuracy = excluded.location_accuracy,
           location_speed = excluded.location_speed,
           location_heading = excluded.location_heading
     where public.driver_locations.last_location_update is null
        or excluded.last_location_update > public.driver_locations.last_location_update;

    return NEW;
end;
$$;

revoke all on function public.trg_mirror_assignment_location() from public;
grant execute on function public.trg_mirror_assignment_location() to service_role;

drop trigger if exists driver_assignments_mirror_location on public.driver_assignments;
create trigger driver_assignments_mirror_location
    after insert or update of current_lat, current_lng, last_location_update
    on public.driver_assignments
    for each row
    execute function public.trg_mirror_assignment_location();

comment on function public.trg_mirror_assignment_location() is
  'Mirrors driver_assignments GPS writes into driver_locations so dispatch eligibility sees the same fix as per-order tracking; never replaces a newer fix.';

-- The usual driver-app publish path upserts driver_locations directly. Mirror
-- that fix onto any LIVE assignment too so customer/store tracking cannot be
-- left behind. pg_trigger_depth() = 1 prevents recursion with the trigger
-- above (its own upsert into driver_locations runs at depth 2).
create or replace function public.trg_mirror_location_to_assignment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_at timestamptz := coalesce(NEW.last_location_update, timezone('utc', now()));
begin
    if NEW.driver_id is null or NEW.current_lat is null or NEW.current_lng is null then
        return NEW;
    end if;

    update public.driver_assignments da
       set current_lat = NEW.current_lat,
           current_lng = NEW.current_lng,
           last_location_update = v_at,
           location_accuracy = NEW.location_accuracy,
           location_speed = NEW.location_speed,
           location_heading = NEW.location_heading
     where da.driver_id = NEW.driver_id
       and public.driver_assignment_status_is_active(da.status)
       and (da.last_location_update is null or v_at >= da.last_location_update);

    return NEW;
end;
$$;

revoke all on function public.trg_mirror_location_to_assignment() from public;
grant execute on function public.trg_mirror_location_to_assignment() to service_role;

drop trigger if exists driver_locations_mirror_to_assignment on public.driver_locations;
create trigger driver_locations_mirror_to_assignment
    after insert or update of current_lat, current_lng, last_location_update
    on public.driver_locations
    for each row
    when (pg_trigger_depth() = 1)
    execute function public.trg_mirror_location_to_assignment();

comment on function public.trg_mirror_location_to_assignment() is
  'Mirrors a published driver_locations fix onto that driver''s live assignments for customer/store tracking; skips nested writes from trg_mirror_assignment_location.';
