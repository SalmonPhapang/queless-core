// ============================================================================
// QUELESS CORE — LIGHTWEIGHT EDGE-CALL TELEMETRY
//
// The Customer app forwards EdgeCallLog events to Firebase Analytics. The
// Driver and Store apps don't ship an analytics stack, so they use this
// lightweight sink instead: it writes a row per failed edge call to the
// shared Supabase `edge_call_events` table — making edge failures queryable
// fleet-wide (e.g. from the admin app) without adding any Firebase or native
// dependency.
//
// queless_core stays free of supabase_flutter: the app injects its own write
// closure (a one-liner against its existing Supabase client). The shared
// logic — which calls to record, how to shape the row, and the fire-and-forget
// error swallowing — lives here in exactly one place.
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'edge_client.dart';

/// Builds an [EdgeCallAnalyticsSink] that records edge-call telemetry to the
/// shared `edge_call_events` Supabase table through the app-supplied
/// [writer] closure.
///
/// Failures are ALWAYS recorded — that's the point (fleet-wide visibility of
/// edge failures). Successes are skipped unless [logSuccesses] is true, so a
/// chatty endpoint can't flood the table (lightweight by default). [app]
/// tags every row (`'driver'`, `'store'`) so fleet dashboards can split by
/// app; the app's writer closure may enrich the event (e.g. add `user_id`)
/// before inserting.
///
/// The returned sink is synchronous and fire-and-forget: the async [writer]
/// is invoked without awaiting and every error it throws is swallowed, so
/// telemetry can never affect the edge call it observes (same guarantee as
/// [EdgeClient._log]).
EdgeCallAnalyticsSink edgeTelemetrySink({
  required Future<void> Function(Map<String, dynamic> event) writer,
  required String app,
  bool logSuccesses = false,
}) {
  return (EdgeCallLog log) {
    // Failures always; successes only when opted in.
    if (log.success && !logSuccesses) return;

    // Promote to locals — Dart can't null-promote public fields like
    // log.status/log.error into the event map.
    final status = log.status;
    final error = log.error;
    final event = <String, dynamic>{
      'app': app,
      'function_name': log.functionName,
      'latency_ms': log.duration.inMilliseconds,
      'success': log.success,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
    };

    Future<void> write() async {
      try {
        await writer(event);
      } catch (e) {
        // Never disturb the edge call — but DO surface telemetry failures in
        // logs: a silent drop would hide a missing migration / RLS problem
        // and make the fleet dashboard look healthy when it isn't.
        debugPrint(
          '[edge-telemetry] failed to record ${log.functionName}: $e',
        );
      }
    }

    unawaited(write());
  };
}
