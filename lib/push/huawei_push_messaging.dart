// ============================================================================
// QUELESS CORE — HUAWEI PUSH KIT ADAPTER
//
// The HMS push counterpart to [FirebasePushMessaging]: it talks to Huawei Push
// Kit for devices that lack Google Play services. The push seam ([PushMessaging])
// was designed to host more than one backend, so adding a second adapter does
// not touch the registrar flow.
//
// The Customer app removed HMS push in the past because the HMS path caused the
// Shorebird release to crash. This adapter exists so HMS-only devices (those
// without Google Play services installed) can still receive push: the
// Customer app can return to a dual FCM + HMS path where the app picks the
// provider that actually works on the device.
//
// This file deliberately does NOT import dart:io: the Customer app ships a PWA
// and the shared layer must stay web-friendly. The app side supplies the OS
// detection and hands the registrar the right implementation.
//
// Prerequisites (app side, not owned by queless_core because they are SDK-level
// and differ per app):
//   * huawei_push package (or the HMS equivalent the app chooses)
//   * AGConnectInstance configured before any push call
//
// Notification *presentation* stays app-side, the same as FCM: this adapter
// stops at registration, token and topic bookkeeping.
// ============================================================================

import 'push_log.dart';
import 'push_messaging.dart';

/// The thinnest surface the adapter needs from the HMS push SDK. The app
/// builds one of these from whatever HMS package it uses, so queless_core
/// never imports `huawei_push` or `agconnect` directly.
abstract class HuaweiPushSdkSurface {
  Future<bool> initialize();
  Future<HuaweiNotificationSettings> getNotificationSettings();
  Future<HuaweiNotificationSettings> requestPermission({
    bool alert = true,
    bool badge = true,
    bool sound = true,
  });
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;
  Future<void> subscribeToTopic(String topic);
  Future<void> unsubscribeFromTopic(String topic);
}

/// HMS analogue of FCM's [NotificationSettings].
abstract class HuaweiNotificationSettings {
  HuaweiAuthorizationStatus get authorizationStatus;
}

/// HMS authorization status values.
abstract class HuaweiAuthorizationStatus {
  bool get authorized;
  bool get denied;
  bool get notDetermined;
}

/// HMS Push Kit adapter for [PushMessaging].
///
/// To avoid compile failures when the HMS SDK is absent, every call is wrapped
/// in a late-bound lookup: the concrete HMS SDK types are resolved only when
/// the app calls [initialize]. If the SDK is not on the device/platform the
/// calls degrade to null/empty instead of throwing, which is what the registrar
/// expects.
///
/// The Customer app drives which providers are tried and in what order; this
/// adapter is the implementation for the HMS leg.
class HuaweiPushMessaging implements PushMessaging {
  HuaweiPushMessaging({this.enabled = true, this.hmsInstanceIdStr});

  /// Per-app feature flag. When false the registrar treats HMS push as
  /// unsupported for this build.
  final bool enabled;

  /// The HMS Instance ID / app ID string the app resolved from its
  /// agconnect-services.json (or equivalent). Passed so queless_core does not
  /// own the HMS SDK dependency directly.
  final String? hmsInstanceIdStr;

  bool _initialized = false;

  @override
  PushProvider get provider => PushProvider.hms;

  @override
  bool get tokenArrivesOnRefreshStream => false;

  // ------------------------------------------------------------------
  // Late-bound SDK surface. Imported only when the app has the HMS SDK
  // on the classpath, so the shared library compiles for the PWA too.
  // ------------------------------------------------------------------

  /// Whether the HMS push SDK is available at runtime.
  bool get _hmsAvailable {
    // The app binds this to whichever HMS SDK import it carries. When null,
    // the HMS SDK was not bundled for this build and every call below degrade
    // to "not available" without throwing.
    return _hmsSdk != null && enabled;
  }

  /// The app-supplied handle to the HMS push SDK surface.
  ///
  /// Set by the app at startup via [configureSdk]. Null until then.
  static HuaweiPushSdkSurface? _hmsSdk;

  /// Called by the app once it has initialised the HMS SDK and can hand back
  /// a thin surface the adapter can use. Kept as a static so the adapter
  /// itself never imports the HMS SDK.
  static void configureSdk(HuaweiPushSdkSurface sdk) => _hmsSdk = sdk;

  // ------------------------------------------------------------------
  // PushMessaging implementation
  // ------------------------------------------------------------------

  @override
  Future<bool> initialize() async {
    if (_initialized) return _hmsAvailable;
    if (!enabled) {
      PushLog.debug('HMS push disabled (enabled=$enabled)');
      return false;
    }
    if (!_hmsAvailable) {
      PushLog.debug('HMS push SDK not available on this platform');
      return false;
    }
    try {
      final ok = await _hmsSdk!.initialize();
      _initialized = ok && _hmsAvailable;
      if (!_initialized) {
        PushLog.debug('HMS push init reported unavailable');
      }
    } catch (e) {
      PushLog.debug('HMS push initialize failed: $e');
      _initialized = false;
    }
    return _initialized;
  }

  @override
  Future<PushAuthorization> notificationSettings() async {
    if (!await _ensureInitialized()) {
      return PushAuthorization.notDetermined;
    }
    try {
      final settings = await _hmsSdk!.getNotificationSettings();
      return _map(settings.authorizationStatus);
    } catch (e) {
      PushLog.debug('HMS getNotificationSettings failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  @override
  Future<PushAuthorization> requestAuthorization() async {
    if (!await _ensureInitialized()) {
      return PushAuthorization.notDetermined;
    }
    try {
      final settings = await _hmsSdk!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return _map(settings.authorizationStatus);
    } catch (e) {
      PushLog.debug('HMS requestPermission failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  @override
  Future<String?> fetchToken() async {
    if (!await _ensureInitialized()) return null;
    try {
      final token = await _hmsSdk!.getToken();
      return (token == null || token.trim().isEmpty) ? null : token.trim();
    } catch (e) {
      PushLog.debug('HMS getToken failed: $e');
      return null;
    }
  }

  @override
  Stream<String> get onTokenRefresh {
    // A getter cannot be async, so return a stream that checks on listen.
    return _onTokenRefreshStream;
  }

  Stream<String> get _onTokenRefreshStream {
    _ensureInitializedSync();
    if (!_initialized || _hmsSdk == null) {
      return const Stream<String>.empty();
    }
    try {
      return _hmsSdk!.onTokenRefresh;
    } catch (e) {
      PushLog.debug('HMS onTokenRefresh unavailable: $e');
      return const Stream<String>.empty();
    }
  }

  /// Synchronous check whether the SDK was already initialized.
  /// Used by the [onTokenRefresh] getter (which cannot be async).
  bool _ensureInitializedSync() {
    if (_initialized) return true;
    // Best-effort synchronous check: if the SDK surface is null we can't
    // initialize synchronously anyway.
    if (_hmsSdk == null || !enabled) {
      _initialized = false;
      return false;
    }
    // We don't have a synchronous way to check, so assume not initialized
    // and let the async methods handle it.
    return false;
  }

  @override
  Future<void> subscribeToTopic(String topic) async {
    if (!await _ensureInitialized()) return;
    try {
      await _hmsSdk!.subscribeToTopic(topic);
    } catch (e) {
      PushLog.debug('HMS subscribeToTopic $topic failed: $e');
    }
  }

  @override
  Future<void> unsubscribeFromTopic(String topic) async {
    if (!await _ensureInitialized()) return;
    try {
      await _hmsSdk!.unsubscribeFromTopic(topic);
    } catch (e) {
      PushLog.debug('HMS unsubscribeFromTopic $topic failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  /// Async initialization check used by all async methods.
  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    return initialize();
  }

  /// HMS-specific authorization status mapping.
  ///
  /// The HMS SDK surface expresses the same concepts as FCM; the labels below
  /// mirror what the app-side HMS SDK exposes. Unknown statuses are treated as
  /// notDetermined so the app never assumes a grant it does not have.
  static PushAuthorization _map(HuaweiAuthorizationStatus status) {
    if (status.authorized) return PushAuthorization.authorized;
    if (status.denied) return PushAuthorization.denied;
    // Provisional-equivalent / not yet asked.
    return PushAuthorization.notDetermined;
  }
}
