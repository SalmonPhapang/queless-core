-- =============================================
-- EDGE CALL TELEMETRY STATS RPC
--
-- Read-only aggregate over public.edge_call_events (written by the Driver &
-- Store apps' shared queless_core edgeTelemetrySink). Consumed by the
-- edge-telemetry edge function, which is service-role guarded — so the admin
-- app never needs direct DB access.
--
-- NOTE: the sinks record FAILURES always and successes only when
-- logSuccesses is enabled in the apps, so failure_rate reflects *stored*
-- events. Turn on logSuccesses fleet-wide for true success rates.
-- =============================================

CREATE OR REPLACE FUNCTION public.get_edge_call_stats(
  p_app text DEFAULT NULL,
  p_function text DEFAULT NULL,
  p_hours integer DEFAULT 24
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result json;
BEGIN
  SELECT json_build_object(
    'window_hours', p_hours,
    'generated_at', timezone('utc', now()),
    'totals', (
      SELECT json_build_object(
        'events', count(*)::int,
        'failures', count(*) FILTER (WHERE NOT success)::int,
        'successes', count(*) FILTER (WHERE success)::int,
        'failure_rate', CASE WHEN count(*) = 0 THEN NULL
          ELSE round(100.0 * count(*) FILTER (WHERE NOT success) / count(*), 2) END,
        'avg_latency_ms', round(avg(latency_ms))::int,
        'p50_latency_ms', percentile_cont(0.50) WITHIN GROUP (ORDER BY latency_ms)::int,
        'p95_latency_ms', percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)::int,
        'p99_latency_ms', percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_ms)::int
      )
      FROM public.edge_call_events
      WHERE created_at >= timezone('utc', now()) - make_interval(hours => COALESCE(p_hours, 24))
        AND (p_app IS NULL OR app = p_app)
        AND (p_function IS NULL OR function_name = p_function)
    ),
    'by_function', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT
          function_name,
          app,
          count(*)::int AS events,
          count(*) FILTER (WHERE NOT success)::int AS failures,
          count(*) FILTER (WHERE success)::int AS successes,
          CASE WHEN count(*) = 0 THEN NULL
            ELSE round(100.0 * count(*) FILTER (WHERE NOT success) / count(*), 2) END
            AS failure_rate,
          round(avg(latency_ms))::int AS avg_latency_ms,
          percentile_cont(0.50) WITHIN GROUP (ORDER BY latency_ms)::int AS p50_latency_ms,
          percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)::int AS p95_latency_ms,
          percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_ms)::int AS p99_latency_ms
        FROM public.edge_call_events
        WHERE created_at >= timezone('utc', now()) - make_interval(hours => COALESCE(p_hours, 24))
          AND (p_app IS NULL OR app = p_app)
          AND (p_function IS NULL OR function_name = p_function)
        GROUP BY function_name, app
        ORDER BY events DESC
      ) t
    ),
    'recent_failures', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT id, app, function_name, latency_ms, status,
               left(error, 500) AS error, created_at
        FROM public.edge_call_events
        WHERE NOT success
          AND created_at >= timezone('utc', now()) - make_interval(hours => COALESCE(p_hours, 24))
          AND (p_app IS NULL OR app = p_app)
          AND (p_function IS NULL OR function_name = p_function)
        ORDER BY created_at DESC
        LIMIT 25
      ) t
    )
  ) INTO result;

  RETURN result;
END;
$$;
