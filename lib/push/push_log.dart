// ============================================================================
// QUELESS CORE — SHARED PUSH LOGGING
//
// The push helpers live in every app, so they need one logging seam: by
// default they print via `debugPrint` (works in debug AND release builds, no
// dependency on any app's logger). Apps that want push diagnostics to land in
// Crashlytics/analytics point [PushLog.sink] at their own logger once at
// startup:
//
//   PushLog.sink = (message) => Logger.debug('[push] $message');
//
// A throwing sink is swallowed, so instrumentation can never break push
// registration.
// ============================================================================

import 'package:flutter/foundation.dart' show debugPrint;

/// Optional per-app log sink for the shared push helpers.
typedef PushLogSink = void Function(String message);

class PushLog {
  /// When null (the default) messages go to [debugPrint].
  static PushLogSink? sink;

  static void debug(String message) {
    final sink = PushLog.sink;
    if (sink == null) {
      debugPrint('[push] $message');
      return;
    }
    try {
      sink(message);
    } catch (_) {
      // A broken logger must never affect push registration.
    }
  }
}
