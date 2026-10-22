// ============================================================================
// QUELESS CORE — FIREBASE CLOUD MESSAGING ADAPTER
//
// The one place any Queless app talks to the FCM SDK for *registration*:
// Firebase bootstrap, permission read/request, device token, token refresh and
// topic subscribe/unsubscribe.
//
// queless_core depends on firebase_core/firebase_messaging with a range wide
// enough for every app's resolution (the Customer app is on
// firebase_messaging 16 / firebase_core 4, the Driver and Store apps on 15 /
// 3), so only the API surface that exists in both is used here. Nothing in
// this file imports dart:io, because the Customer app ships as a PWA too.
//
// The Customer app no longer supports HMS: the HMS push/notification path was
// removed because it caused the Shorebird release to crash. The shared push
// layer therefore targets FCM-only devices.
//
// Notification *presentation* deliberately stays app-side: rendering a push as
// a local notification and routing its tap needs each app's screens, so the
// shared code stops at "this device is registered and subscribed".
// ============================================================================

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'push_log.dart';
import 'push_messaging.dart';

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging({this.enabled = true, this.supportWeb = false});

  /// Per-app feature flag (e.g. the Driver app's `AppConfig.featureFirebase`).
  /// When false the registrar treats push as unsupported and does nothing.
  final bool enabled;

  /// FCM works on web, but the Queless apps currently skip push in the PWA:
  /// keep `false` unless an app wires a VAPID key and wants web tokens.
  final bool supportWeb;

  bool _initialized = false;

  @override
  PushProvider get provider => PushProvider.fcm;

  @override
  bool get tokenArrivesOnRefreshStream => false;

  /// Platform the FCM plugin actually implements. Desktop builds (and
  /// `flutter test`) must not touch `FirebaseMessaging.instance`: it throws
  /// `MissingPluginException`/unimplemented there.
  static bool get _platformSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (!enabled || !_platformSupported || (kIsWeb && !supportWeb)) {
      PushLog.debug(
        'push disabled (enabled=$enabled, web=$kIsWeb, '
        'platform=$defaultTargetPlatform)',
      );
      return false;
    }
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    } catch (e) {
      PushLog.debug('Firebase.initializeApp failed: $e');
    }
    _initialized = Firebase.apps.isNotEmpty;
    if (!_initialized) {
      PushLog.debug('Firebase not configured; push stays disabled');
    }
    return _initialized;
  }

  @override
  Future<PushAuthorization> notificationSettings() async {
    if (!await initialize()) return PushAuthorization.notDetermined;
    try {
      return _map(await FirebaseMessaging.instance.getNotificationSettings());
    } catch (e) {
      // Undecided is the safe default: it never blocks a registration that
      // would have succeeded, and it never reports a grant that isn't there.
      PushLog.debug('getNotificationSettings failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  @override
  Future<PushAuthorization> requestAuthorization() async {
    if (!await initialize()) return PushAuthorization.notDetermined;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return _map(settings);
    } catch (e) {
      PushLog.debug('requestPermission failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  @override
  Future<String?> fetchToken() async {
    if (!await initialize()) return null;
    final token = await FirebaseMessaging.instance.getToken();
    return (token == null || token.trim().isEmpty) ? null : token;
  }

  @override
  Stream<String> get onTokenRefresh => _initialized
      ? FirebaseMessaging.instance.onTokenRefresh
      : const Stream<String>.empty();

  @override
  Future<void> subscribeToTopic(String topic) async {
    if (!await initialize()) return;
    await FirebaseMessaging.instance.subscribeToTopic(topic);
  }

  @override
  Future<void> unsubscribeFromTopic(String topic) async {
    if (!await initialize()) return;
    await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
  }

  /// Deliberately tolerant of unknown statuses: a future SDK version adding an
  /// enum value must not make the apps fail to compile, and an unrecognised
  /// status must not be read as a grant.
  static PushAuthorization _map(NotificationSettings settings) {
    switch (settings.authorizationStatus) {
      case AuthorizationStatus.authorized:
        return PushAuthorization.authorized;
      case AuthorizationStatus.provisional:
        return PushAuthorization.provisional;
      case AuthorizationStatus.denied:
        return PushAuthorization.denied;
      default:
        return PushAuthorization.notDetermined;
    }
  }
}
