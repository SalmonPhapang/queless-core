// ============================================================================
// QUELESS CORE — SHARED SUPABASE STARTUP GUARD
//
// All three Queless apps (customer, driver, store) initialize Supabase the
// same way: run it exactly once (so startup retries — e.g. after a timeout —
// can't stack duplicate initializations or side effects like the edge logger
// install), and opt into edge-call instrumentation via [enableEdgeLogging].
//
// The apps differ only in HOW they obtain their URL/anon key and whether they
// wrap the init in extra logging — they pass that as the [init] closure. The
// guard, the flag, and the logger install all live here, in one place.
//
// Concurrency: [initialize] memoizes a shared [Future], so even if multiple
// callers invoke it before the first run completes (e.g. several screens
// racing at cold start), they all await the SAME in-flight future — Supabase
// is never initialized twice. If the run fails, the memo is cleared so a
// retry can succeed.
// ============================================================================

import 'edge_client.dart';

/// Shared, idempotent Supabase startup helper used by the Customer, Driver,
/// and Store apps.
class SupabaseStartup {
  /// Memoized in-flight/completed initialization future. Non-null from the
  /// moment the first [initialize] call starts until the app resets it (or a
  /// failed run clears it for retry).
  static Future<void>? _initFuture;

  /// Per-app opt-out for edge-call instrumentation. Set to `false` in an
  /// app's startup (before [initialize]) to silence the [EdgeClient] logger
  /// in that app. Defaults to on so regressions stay visible in all builds.
  static bool enableEdgeLogging = true;

  /// Optional per-app forwarder for edge-call telemetry. When set before
  /// [initialize], every [EdgeCallLog] (function name, latency,
  /// success/failure) is piped to the app's analytics service in addition to
  /// the default debug log — so failed edge calls become analytics events
  /// with latency across the fleet. Apps without an analytics service simply
  /// leave this null (the capability stays available for later).
  static EdgeCallAnalyticsSink? analyticsSink;

  /// Runs [init] exactly once — even under concurrent calls, which all await
  /// the same memoized future. On success, installs the shared edge logger
  /// via [EdgeClient.installDefaultLogger] when [enableEdgeLogging] is true.
  /// If [init] throws, the memo is cleared so a retry (e.g. after a startup
  /// timeout) can succeed; concurrent waiters all see the same error.
  static Future<void> initialize(Future<void> Function() init) {
    return _initFuture ??= _doInitialize(init);
  }

  static Future<void> _doInitialize(Future<void> Function() init) async {
    try {
      await init();
    } catch (_) {
      // A failed attempt must stay retryable: drop the memo so the next
      // caller starts a fresh run instead of awaiting a failed future.
      // Deferred a microtask so this runs AFTER the `??=` in [initialize]
      // assigns the failed future — otherwise a synchronously-throwing
      // [init] would permanently memoize the failure.
      Future.microtask(() => _initFuture = null);
      rethrow;
    }
    if (enableEdgeLogging) {
      EdgeClient.installDefaultLogger(forwardTo: analyticsSink);
    }
  }

  /// Resets the memoized future — primarily for tests.
  static void reset() => _initFuture = null;
}
