// ============================================================================
// QUELESS CORE — EDGE FUNCTION INVOKE HELPER
//
// Every Queless app calls Supabase edge functions (orders-create, orders-status,
// paystack-settlements, payouts-process, ...). This helper standardizes the
// invoke call + error handling so the three apps don't each hand-roll it.
//
// Apps build their shared client once, e.g. in SupabaseConfig:
//
//   static final EdgeClient edge = EdgeClient.supabase(client.functions);
//
// ...then call it from any service:
//
//   final data = await SupabaseConfig.edge.call('orders-status', body: {...});
//
// The [EdgeClient.supabase] factory binds a Supabase [FunctionsClient] and
// normalizes failures itself: functions_client v2 throws [FunctionException]
// on any non-2xx response, which the factory converts into
// [EdgeFunctionException] with the server's error message + HTTP status.
//
// queless_core depends only on the small `functions_client` package (NOT
// supabase_flutter — the three apps pin different majors) plus Flutter's
// bundled `foundation` for debugPrint. All three apps resolve
// functions_client 2.5.0, so the exception type is shared.
//
// For invoke calls that need custom options (headers, files, queryParameters),
// build an [EdgeClient] with a hand-rolled [EdgeInvoker] instead:
//
//   final edge = EdgeClient(
//     (name, body) async { ... custom invoke ... },
//   );
// ============================================================================

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:functions_client/functions_client.dart';

/// Signature every caller implements to actually hit the edge function.
typedef EdgeInvoker = Future<dynamic> Function(
  String functionName,
  Map<String, dynamic> body, {
  Map<String, String>? headers,
});

/// A single edge-function call's outcome, for logging/instrumentation.
class EdgeCallLog {
  final String functionName;
  final Duration duration;
  final bool success;
  final int? status;
  final String? error;

  const EdgeCallLog({
    required this.functionName,
    required this.duration,
    required this.success,
    this.status,
    this.error,
  });
}

/// Hook apps can install to observe every edge-function call.
///
/// Receives an [EdgeCallLog] with the function name, latency, and
/// success/failure (plus HTTP status + error message on failure). Wire it
/// once at startup (e.g. in `SupabaseConfig.initialize`) to catch regressions
/// across all three apps. When null, no timing is recorded (zero overhead).
typedef EdgeCallLogger = void Function(EdgeCallLog log);

/// Optional sink apps pass to [EdgeClient.installDefaultLogger] to forward
/// every [EdgeCallLog] (function name, latency, success/failure) to their
/// analytics service — so failed edge calls become analytics events with
/// latency across the fleet. Must be sync and non-throwing (the default
/// logger swallows sink errors, and [EdgeClient._log] guards the whole
/// callback, so analytics can never affect the edge call it observes).
typedef EdgeCallAnalyticsSink = void Function(EdgeCallLog log);

class EdgeFunctionException implements Exception {
  final String message;
  final int? status;
  final dynamic data;

  const EdgeFunctionException(this.message, {this.status, this.data});

  @override
  String toString() => 'EdgeFunctionException(${status ?? "?"}): $message';
}

class EdgeClient {
  final EdgeInvoker _invoker;

  /// Optional global logger for every edge-function call. Apps install this
  /// once at startup (e.g. in `SupabaseConfig.initialize`) to log name,
  /// latency and success/failure. Null by default = no instrumentation.
  static EdgeCallLogger? logger;

  const EdgeClient(this._invoker);

  /// Install the shared default logger: prints every edge-function call
  /// (`[edge] OK|FAIL <name> <ms> (status) — error`) via [debugPrint], which
  /// works in debug AND release builds. Idempotent — safe to call from every
  /// app's startup. Apps can instead set [logger] to their own hook.
  ///
  /// Pass [forwardTo] to additionally pipe every [EdgeCallLog] into an
  /// analytics service (e.g. [EdgeCallAnalyticsSink] wired to Firebase
  /// Analytics) so edge failures + latency become fleet-wide metrics. The
  /// sink runs after the debug print and any error it throws is swallowed,
  /// so instrumentation can never disturb the call being observed.
  static void installDefaultLogger({EdgeCallAnalyticsSink? forwardTo}) {
    logger = (log) {
      final marker = log.success ? 'OK' : 'FAIL';
      final status = log.status != null ? ' (${log.status})' : '';
      final error = log.error != null ? ' — ${log.error}' : '';
      debugPrint(
        '[edge] $marker ${log.functionName} '
        '${log.duration.inMilliseconds}ms$status$error',
      );
      final sink = forwardTo;
      if (sink != null) {
        try {
          sink(log);
        } catch (_) {
          // Never let analytics break edge calls or the debug log.
        }
      }
    };
  }

  /// Build an [EdgeClient] bound to a Supabase [FunctionsClient].
  ///
  /// functions_client v2 throws [FunctionException] on any non-2xx status;
  /// this factory converts it into an [EdgeFunctionException] carrying the
  /// server's `error` (or `message`) field and the HTTP status, so callers
  /// get a clean, consistent failure without hand-rolling extraction.
  factory EdgeClient.supabase(FunctionsClient functions) {
    return EdgeClient((functionName, body, {headers}) async {
      try {
        final result = await functions.invoke(
          functionName,
          body: body,
          headers: headers,
        );
        return result.data;
      } on FunctionException catch (e) {
        final data = e.details;
        final error = data is Map
            ? data['error']?.toString() ??
                data['message']?.toString() ??
                'Edge function $functionName failed'
            : 'Edge function $functionName failed';
        throw EdgeFunctionException(error, status: e.status, data: data);
      }
    });
  }

  /// Invoke [functionName] with [body] (and optional per-call [headers], e.g.
  /// for functions that need explicit anon-key auth) and return the decoded
  /// response data. Throws [EdgeFunctionException] on any failure.
  Future<dynamic> call(
    String functionName, {
    Map<String, dynamic> body = const {},
    Map<String, String>? headers,
  }) async {
    final watch = EdgeClient.logger == null ? null : (Stopwatch()..start());
    try {
      final data = await _invoker(functionName, body, headers: headers);
      // Edge functions conventionally return {error: ...} on failure; a
      // payload map that legitimately carries an 'error' FIELD is rare, but
      // callers can bypass this by throwing from their invoker directly.
      if (data is Map && data['error'] != null) {
        throw EdgeFunctionException(
          data['error'].toString(),
          data: data,
        );
      }
      _log(watch, functionName, success: true);
      return data;
    } on EdgeFunctionException catch (e) {
      _log(
        watch,
        functionName,
        success: false,
        status: e.status,
        error: e.message,
      );
      rethrow;
    } catch (e) {
      _log(watch, functionName, success: false, error: e.toString());
      throw EdgeFunctionException(
        'Edge function $functionName failed: $e',
      );
    }
  }

  static void _log(
    Stopwatch? watch,
    String functionName, {
    required bool success,
    int? status,
    String? error,
  }) {
    final logger = EdgeClient.logger;
    if (logger == null) return;
    try {
      logger(EdgeCallLog(
        functionName: functionName,
        duration: watch?.elapsed ?? Duration.zero,
        success: success,
        status: status,
        error: error,
      ));
    } catch (_) {
      // Instrumentation must never affect the call it's observing — a
      // throwing logger is swallowed so the edge call outcome is intact.
    }
  }
}
