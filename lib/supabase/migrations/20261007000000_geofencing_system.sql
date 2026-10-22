-- ============================================================================
-- Geofencing System — Phase 2 of the Queless Safety & Delivery Geofencing Roadmap
-- Migration: 20261007000000_geofencing_system.sql
--
-- Deploys:
--  1. PostGIS extension (idempotent)
--  2. service_zones table + GIST spatial indexes
--  3. store delivery columns (delivery_enabled, delivery_radius_km,
--     delivery_polygon, minimum_order_amount, delivery_fee, store_location)
--  4. RLS policies:
--     - anon/authenticated: read-only non-sensitive zone state (no risk_level, no notes)
--     - service_role: full CRUD
--  5. check_delivery_eligibility() authoritative RPC
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. PostGIS
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- 2. Enums
-- ----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE zone_type_enum AS ENUM ('SERVICE_AREA', 'SAFETY_ZONE', 'STORE_DELIVERY_ZONE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE risk_level_enum AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE zone_status_enum AS ENUM ('ACTIVE', 'INACTIVE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE safety_action_enum AS ENUM ('NORMAL', 'LIMITED', 'RESTRICTED', 'BLOCKED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ----------------------------------------------------------------------------
-- 3. service_zones
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.service_zones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    zone_type zone_type_enum NOT NULL DEFAULT 'SAFETY_ZONE',
    risk_level risk_level_enum NOT NULL DEFAULT 'LOW',
    boundary extensions.geography(Polygon, 4326) NOT NULL,
    status zone_status_enum NOT NULL DEFAULT 'ACTIVE',
    browsing_enabled BOOLEAN NOT NULL DEFAULT true,
    ordering_enabled BOOLEAN NOT NULL DEFAULT true,
    delivery_enabled BOOLEAN NOT NULL DEFAULT true,
    active_from TIMESTAMPTZ DEFAULT NULL,
    active_until TIMESTAMPTZ DEFAULT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

-- Spatial indexing
CREATE INDEX IF NOT EXISTS idx_service_zones_boundary
    ON public.service_zones USING GIST (boundary);

CREATE INDEX IF NOT EXISTS idx_service_zones_active_status
    ON public.service_zones (status, zone_type, active_from, active_until);

ALTER TABLE public.service_zones ENABLE ROW LEVEL SECURITY;

-- Public/Clients: read-only non-sensitive state (no risk_level, no notes)
DROP POLICY IF EXISTS service_zones_public_read ON public.service_zones;
CREATE POLICY service_zones_public_read ON public.service_zones
    FOR SELECT
    USING (status = 'ACTIVE')
    WITH CHECK (false);

-- Admins/service_role: full access
GRANT ALL ON public.service_zones TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Extend stores table
-- ----------------------------------------------------------------------------
ALTER TABLE public.stores
    ADD COLUMN IF NOT EXISTS delivery_enabled BOOLEAN DEFAULT true,
    ADD COLUMN IF NOT EXISTS delivery_radius_km NUMERIC(5, 2) DEFAULT 5.0,
    ADD COLUMN IF NOT EXISTS delivery_polygon extensions.geography(Polygon, 4326) DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS minimum_order_amount NUMERIC(10, 2) DEFAULT 0.00,
    ADD COLUMN IF NOT EXISTS delivery_fee NUMERIC(10, 2) DEFAULT 0.00,
    ADD COLUMN IF NOT EXISTS store_location extensions.geography(Point, 4326);

CREATE INDEX IF NOT EXISTS idx_stores_location
    ON public.stores USING GIST (store_location);

CREATE INDEX IF NOT EXISTS idx_stores_delivery_polygon
    ON public.stores USING GIST (delivery_polygon);

-- ----------------------------------------------------------------------------
-- 5. check_delivery_eligibility() — authoritative geo-eligibility RPC
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_delivery_eligibility(
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_store_id UUID DEFAULT NULL
)
RETURNS TABLE (
    is_eligible BOOLEAN,
    can_browse BOOLEAN,
    can_order BOOLEAN,
    can_deliver BOOLEAN,
    status_code VARCHAR(50),
    user_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_point extensions.geography;
    v_in_service_area BOOLEAN := FALSE;
    v_safety_zone RECORD;
    v_store RECORD;
    v_store_distance_meters DOUBLE PRECISION;
BEGIN
    -- Build geography point from lat/lng (note: ST_MakePoint takes lon, lat)
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;

    -- 1. Check Queless Service Area
    SELECT EXISTS (
        SELECT 1 FROM public.service_zones
        WHERE zone_type = 'SERVICE_AREA'
          AND status = 'ACTIVE'
          AND extensions.ST_Contains(boundary::extensions.geometry, v_point::extensions.geometry)
    ) INTO v_in_service_area;

    IF NOT v_in_service_area THEN
        RETURN QUERY SELECT
            FALSE, TRUE, FALSE, FALSE,
            'OUTSIDE_SERVICE_AREA'::VARCHAR,
            'Queless is not available in your current area yet. We are continuously expanding!'::TEXT;
        RETURN;
    END IF;

    -- 2. Check Safety / Restricted Zones (highest risk first)
    SELECT * INTO v_safety_zone
    FROM public.service_zones
    WHERE zone_type = 'SAFETY_ZONE'
      AND status = 'ACTIVE'
      AND (active_from IS NULL OR active_from <= clock_timestamp())
      AND (active_until IS NULL OR active_until >= clock_timestamp())
      AND extensions.ST_Contains(boundary::extensions.geometry, v_point::extensions.geometry)
    ORDER BY
        CASE risk_level
            WHEN 'CRITICAL' THEN 1
            WHEN 'HIGH' THEN 2
            WHEN 'MEDIUM' THEN 3
            ELSE 4
        END ASC
    LIMIT 1;

    IF FOUND THEN
        IF NOT v_safety_zone.delivery_enabled THEN
            RETURN QUERY SELECT
                FALSE,
                v_safety_zone.browsing_enabled,
                FALSE,
                FALSE,
                'DELIVERY_RESTRICTED'::VARCHAR,
                'For the safety of our community and driver partners, deliveries are currently unavailable at this location.'::TEXT;
            RETURN;
        END IF;
    END IF;

    -- 3. Check Store Specific Coverage (if store_id passed)
    IF p_store_id IS NOT NULL THEN
        SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;

        IF NOT FOUND OR NOT v_store.delivery_enabled THEN
            RETURN QUERY SELECT
                FALSE, TRUE, FALSE, FALSE,
                'STORE_DELIVERY_DISABLED'::VARCHAR,
                'This store is currently not fulfilling deliveries.'::TEXT;
            RETURN;
        END IF;

        -- Polygon check takes priority over radius
        IF v_store.delivery_polygon IS NOT NULL THEN
            IF NOT extensions.ST_Contains(v_store.delivery_polygon::extensions.geometry, v_point::extensions.geometry) THEN
                RETURN QUERY SELECT
                    FALSE, TRUE, FALSE, FALSE,
                    'OUTSIDE_STORE_COVERAGE'::VARCHAR,
                    'This location is outside the store delivery zone.'::TEXT;
                RETURN;
            END IF;
        ELSE
            -- Fallback to radius (store_location must exist)
            IF v_store.store_location IS NULL THEN
                RETURN QUERY SELECT
                    FALSE, TRUE, FALSE, FALSE,
                    'STORE_LOCATION_MISSING'::VARCHAR,
                    'This store has not configured its delivery location yet.'::TEXT;
                RETURN;
            END IF;

            v_store_distance_meters := extensions.ST_Distance(v_store.store_location, v_point);
            IF v_store_distance_meters > (v_store.delivery_radius_km * 1000) THEN
                RETURN QUERY SELECT
                    FALSE, TRUE, FALSE, FALSE,
                    'EXCEEDS_DELIVERY_RADIUS'::VARCHAR,
                    'This address is beyond the maximum delivery range for this merchant.'::TEXT;
                RETURN;
            END IF;
        END IF;
    END IF;

    -- All checks passed
    RETURN QUERY SELECT
        TRUE, TRUE, TRUE, TRUE,
        'OK'::VARCHAR,
        'Delivery is available.'::TEXT;
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public.check_delivery_eligibility(double precision, double precision, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_delivery_eligibility(double precision, double precision, uuid) TO anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. Retention purge schedules (Phase 18 §3, §7, §8)
--    Only install if pg_cron is available; never fail the migration.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_has_cron boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO v_has_cron;
    IF v_has_cron THEN
        -- Conversation + message purge: daily at 02:00 SAST (UTC+2) = 00:00 UTC
        PERFORM cron.schedule(
            'qai_purge_conversations_daily',
            '0 0 * * *',
            $$SELECT public.qai_purge_expired_conversations(10000)$$
        );
        -- Analytics event purge: daily at 02:30 SAST
        PERFORM cron.schedule(
            'qai_purge_analytics_daily',
            '30 0 * * *',
            $$SELECT public.qai_purge_expired_analytics(50000)$$
        );
        -- Behavioural ai_events purge: weekly Sunday 03:00 SAST
        PERFORM cron.schedule(
            'qai_purge_events_weekly',
            '0 3 * * 0',
            $$SELECT public.qai_purge_expired_events(100000)$$
        );
    END IF;
END $$;

COMMENT ON TABLE public.service_zones IS 'Queless geofencing system — service areas, safety zones, and store delivery zones. Phase 2 of the geofencing roadmap. risk_level and notes are admin-only fields never exposed to clients.';
