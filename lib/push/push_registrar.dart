// ==============================================================================
// QUELESS CORE — SHARED PUSH REGISTRATION
//
// The single implementation of "make this device reachable by push for this
// user", used by the Customer, Driver and Store apps. Before this existed each
// app had its own copy (the Customer app's NotificationService, the Driver
// app's FcmService.registerDriver *and* DriverService.updateFCMToken, and the
// Store app's FcmService.syncTokenForUser) and a fix in one landed in none of
// the others.
//
// The flow, in order:
//   1. resolve the signed-in user (explicit id, else the session resolver)
//   2. skip when this user is already registered in this app session
//   3. read the OS authorization, prompting only when the caller allows it
//   4. fetch the device token (retried), falling back to the cached token
//   5. upsert one row per (user_id, token) so every signed-in device is reached
//   6. subscribe the requested FCM topics
//
// Two policies are deliberately different from the hand-rolled versions:
//   * an unregistered device is never written to Supabase while notifications
//     are denied — a token row that cannot deliver is dead weight (the Store
//     app used to write one anyway);
//   * `authorized` and `provisional` both count as granted, and the Android 13
//     POST_NOTIFICATIONS prompt is requested through one shared hook.
//
// Nothing here throws: registration runs on the startup path, so every failure
// is contained and reported as a [PushRegistrationOutcome] the caller can log
// or act on.
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'push_log.dart';
import 'push_messaging.dart';
import 'push_state_cache.dart';
import 'push_token_store.dart';
import 'push_topics.dart';

/// Resolves the currently signed-in user id, or null when signed out.
typedef PushSessionUserId = String? Function();

/// Requests the Android 13+ POST_NOTIFICATIONS permission through the app's
/// own flutter_local_notifications plugin.
///
/// It lives behind a hook because queless_core cannot own that plugin: the
/// apps resolve different majors (19.x in Customer, 17.x in Driver/Store), and
/// a local-notification permission is what makes a *locally shown* push
/// visible. Called only when a prompt is actually being attempted, and only on
/// Android, so the user is never asked twice.
typedef PushAndroidNotificationPermission = Future<void> Function();

/// How a registration attempt ended.
enum PushRegistrationOutcome {
  /// Token row written (and topics subscribed).
  registered,

  /// This user was already confirmed earlier in this app session.
  alreadyRegistered,

  /// Push is switched off for this build/platform, or Firebase is unconfigured.
  unsupported,

  /// No signed-in user to attach a token to.
  noSession,

  /// Notifications are not authorised, so no row was written.
  permissionDenied,

  /// No token was available (offline cold start); the next launch retries.
  noToken,

  /// The token could not be written to Supabase.
  saveFailed,

  /// Something else went wrong; the reason is logged.
  failed,
}

/// The result of one [PushRegistrar.register] call.
class PushRegistrationResult {
  const PushRegistrationResult({
    required this.outcome,
    this.userId,
    this.token,
    this.provider = PushProvider.fcm,
    this.authorization = PushAuthorization.notDetermined,
    this.topics = const <String>{},
    this.error,
  });

  final PushRegistrationOutcome outcome;
  final String? userId;
  final String? token;
  final PushProvider provider;
  final PushAuthorization authorization;

  /// Topics confirmed subscribed as part of this call.
  final Set<String> topics;

  final Object? error;

  /// True when the device is registered for [userId] as a result of this call.
  bool get isRegistered =>
      outcome == PushRegistrationOutcome.registered ||
      outcome == PushRegistrationOutcome.alreadyRegistered;

  @override
  String toString() => 'PushRegistrationResult(${outcome.name}'
      '${userId == null ? '' : ', user=$userId'}'
      '${token == null ? '' : ', ${provider.label}=$token'}'
      ', auth=${authorization.name})';
}

class PushRegistrar {
  PushRegistrar({
    required PushMessaging messaging,
    required PushTokenStore store,
    required PushStateCache cache,
    PushSessionUserId? sessionUserId,
    PushAndroidNotificationPermission? requestAndroidNotificationPermission,
    this.tokenFetchAttempts = 3,
  })  : _messaging = messaging,
        _store = store,
        _cache = cache,
        _sessionUserId = sessionUserId,
        _androidNotificationPermission = requestAndroidNotificationPermission;

  /// How many times a cold start asks for a device token before giving up and
  /// falling back to the cached one. Tests pin this to 1 to stay fast.
  final int tokenFetchAttempts;

  final PushMessaging _messaging;
  final PushTokenStore _store;
  final PushStateCache _cache;
  final PushSessionUserId? _sessionUserId;
  final PushAndroidNotificationPermission? _androidNotificationPermission;

  Future<bool>? _initialization;
  StreamSubscription<String>? _refreshSubscription;
  String? _registeredUserId;
  final Set<String> _sessionTopics = <String>{};

  /// Topics this device is believed to hold: the ones this session subscribed
  /// plus the ones cached from earlier sessions. Loaded once, then kept in
  /// step — persisting only the session set would erase everything a previous
  /// session subscribed the first time the app subscribes anything.
  Set<String>? _knownTopics;

  PushProvider get provider => _messaging.provider;

  /// The user whose device token row is confirmed for this app session.
  String? get registeredUserId => _registeredUserId;

  bool get isRegistered => _registeredUserId != null;

  /// Brings the push backend up once; the answer is memoized. Returns false
  /// when push is unavailable, in which case every other call is a no-op.
  Future<bool> initialize() => _initialization ??= _messaging.initialize();

  /// Passive authorization read — never prompts. Used by settings UI.
  Future<PushAuthorization> notificationSettings() async {
    if (!await initialize()) return PushAuthorization.notDetermined;
    try {
      return await _messaging.notificationSettings();
    } catch (e) {
      PushLog.debug('reading notification settings failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  /// Whether pushes may currently be delivered.
  Future<bool> isAuthorized() async =>
      (await notificationSettings()).allowsPush;

  /// Prompts for notification permission (no-op once the OS has an answer).
  ///
  /// For permission screens and onboarding: unlike [register] this always asks
  /// when the answer is still undecided, and never touches the token.
  Future<bool> requestPermission() async {
    if (!await initialize()) return false;
    if ((await notificationSettings()).allowsPush) return true;
    return (await _requestAuthorization()).allowsPush;
  }

  /// Registers this device for push on behalf of [userId] (defaulting to the
  /// session resolver).
  ///
  /// Called on every cold start: FCM drops a registration token after long
  /// inactivity, which also clears the app's topic subscriptions, and the
  /// token can rotate while the app is closed. The once-per-session guard
  /// keeps the *later* calls — sign-in, profile refresh, resume — cheap, so
  /// passing [force] from those is rarely needed.
  ///
  /// [requestPermissionIfNeeded] stays false for startup callers: the OS
  /// prompt belongs to the permission screen, not to every launch.
  /// [replaceTopics] switches the topic sync from "add these" to "exactly
  /// these", unsubscribing topics this device subscribed in an earlier session
  /// (see [syncTopics]).
  Future<PushRegistrationResult> register({
    String? userId,
    Iterable<String> topics = const <String>[],
    bool replaceTopics = false,
    bool requestPermissionIfNeeded = false,
    bool force = false,
  }) async {
    final target = (userId ?? _sessionUserId?.call())?.trim();
    if (target == null || target.isEmpty) {
      PushLog.debug('push registration skipped: no signed-in user');
      return const PushRegistrationResult(
        outcome: PushRegistrationOutcome.noSession,
      );
    }

    if (!await initialize()) {
      return PushRegistrationResult(
        outcome: PushRegistrationOutcome.unsupported,
        userId: target,
        provider: provider,
      );
    }

    if (!force && _registeredUserId == target) {
      return PushRegistrationResult(
        outcome: PushRegistrationOutcome.alreadyRegistered,
        userId: target,
        provider: provider,
        authorization: await notificationSettings(),
      );
    }

    try {
      final authorization = await _authorize(
        requestPermissionIfNeeded: requestPermissionIfNeeded,
      );

      // The cached token is the fallback for a cold start that cannot reach
      // FCM yet, so the stored row is refreshed instead of going stale.
      final cached = await _cache.readToken();
      final fresh = await _fetchTokenWithRetry();
      if (fresh != null) {
        await _cache.writeToken(
          PushCachedToken(token: fresh, provider: PushProvider.fcm),
        );
      }
      final token = fresh ?? cached?.token;

      if (token == null || token.trim().isEmpty) {
        _registeredUserId = null;
        PushLog.debug('no push token available; will retry on next launch');
        return PushRegistrationResult(
          outcome: PushRegistrationOutcome.noToken,
          userId: target,
          provider: provider,
          authorization: authorization,
        );
      }

      if (!authorization.allowsPush) {
        _registeredUserId = null;
        PushLog.debug(
          'push registration skipped: notifications not authorised '
          '(${authorization.name})',
        );
        return PushRegistrationResult(
          outcome: PushRegistrationOutcome.permissionDenied,
          userId: target,
          token: token,
          provider: provider,
          authorization: authorization,
        );
      }

      try {
        await _store.saveDeviceToken(userId: target, token: token);
      } catch (e) {
        _registeredUserId = null;
        PushLog.debug('saving the push token failed: $e');
        return PushRegistrationResult(
          outcome: PushRegistrationOutcome.saveFailed,
          userId: target,
          token: token,
          provider: provider,
          authorization: authorization,
          error: e,
        );
      }

      _registeredUserId = target;
      PushLog.debug('push registered for $target (${provider.label})');

      final confirmed = await syncTopics(topics, replaceTopics: replaceTopics);
      return PushRegistrationResult(
        outcome: PushRegistrationOutcome.registered,
        userId: target,
        token: token,
        provider: provider,
        authorization: authorization,
        topics: confirmed,
      );
    } catch (e) {
      _registeredUserId = null;
      PushLog.debug('push registration failed: $e');
      return PushRegistrationResult(
        outcome: PushRegistrationOutcome.failed,
        userId: target,
        provider: provider,
        error: e,
      );
    }
  }

  /// Listens for rotated tokens and keeps Supabase in step.
  ///
  /// It fires for tokens that arrive before the session is restored: those are
  /// cached and attached on the next [register]. Idempotent — safe to call from
  /// every startup.
  Future<bool> attachTokenRefreshListener() async {
    if (_refreshSubscription != null) return true;
    if (!await initialize()) return false;
    try {
      _refreshSubscription = _messaging.onTokenRefresh.listen(
        (token) => unawaited(_handleRotatedToken(token)),
        onError: (Object error) =>
            PushLog.debug('push token refresh stream error: $error'),
      );
      return true;
    } catch (e) {
      PushLog.debug('listening for push token refreshes failed: $e');
      return false;
    }
  }

  /// Subscribes this device to [topic] (idempotent) and records it.
  Future<bool> subscribeToTopic(String topic) async {
    final trimmed = topic.trim();
    if (trimmed.isEmpty) return false;
    if (!PushTopics.isValid(trimmed)) {
      PushLog.debug('ignoring invalid push topic "$topic"');
      return false;
    }
    if (!await initialize()) return false;
    try {
      await _messaging.subscribeToTopic(trimmed);
      _sessionTopics.add(trimmed);
      final known = await _known();
      known.add(trimmed);
      await _cache.writeKnownTopics(known);
      PushLog.debug('subscribed to push topic $trimmed');
      return true;
    } catch (e) {
      PushLog.debug('subscribing to push topic $trimmed failed: $e');
      return false;
    }
  }

  Future<void> unsubscribeFromTopic(String topic) =>
      unsubscribeFromTopics(<String>[topic]);

  /// Unsubscribes this device from [topics], skipping blanks/duplicates.
  ///
  /// One failing topic never stops the rest: a stale subscription that cannot
  /// be removed must not block a sign-out.
  Future<void> unsubscribeFromTopics(Iterable<String> topics) async {
    final targets = PushTopics.normalize(topics);
    if (targets.isEmpty) return;
    if (!await initialize()) return;
    final known = await _known();
    for (final topic in targets) {
      try {
        await _messaging.unsubscribeFromTopic(topic);
        _sessionTopics.remove(topic);
        known.remove(topic);
        PushLog.debug('unsubscribed from push topic $topic');
      } catch (e) {
        PushLog.debug('unsubscribing from push topic $topic failed: $e');
      }
    }
    await _cache.writeKnownTopics(known);
  }

  /// Brings this device's subscriptions in line with [topics].
  ///
  /// The wanted set is always (re)subscribed rather than trusted against the
  /// cached set — FCM drops subscriptions after long inactivity, and a device
  /// that believes it is subscribed while FCM disagrees is silently deaf.
  ///
  /// With [replaceTopics] the topics this device is known to have subscribed
  /// (this session *and* any earlier one) that are missing from [topics] are
  /// unsubscribed — that is what stops pushes for a store a user no longer
  /// owns. Returns the topics now subscribed.
  Future<Set<String>> syncTopics(
    Iterable<String> topics, {
    bool replaceTopics = false,
  }) async {
    final wanted = PushTopics.normalize(topics);
    final known = await _known();

    for (final topic in wanted) {
      await subscribeToTopic(topic);
    }

    if (replaceTopics) {
      await unsubscribeFromTopics(known.difference(wanted));
    }

    return wanted;
  }

  /// Drops every subscription this device is known to hold. Used on sign-out,
  /// so the next user of the device is not sent the previous one's pushes.
  Future<void> unsubscribeAll() async {
    final known = await _known();
    if (known.isEmpty) return;
    await unsubscribeFromTopics(known);
  }

  /// Removes this device's token row and topic subscriptions on sign-out.
  ///
  /// The delete is scoped to the exact cached token and app audience, so other
  /// devices and other Queless apps stay registered. Failures are logged but
  /// never prevent the local session teardown.
  Future<void> clearRegistration() async {
    final userId = _registeredUserId ?? _sessionUserId?.call();
    final cached = await _cache.readToken();
    if (userId != null && userId.trim().isNotEmpty && cached != null) {
      try {
        await _store.deleteDeviceToken(
          userId: userId.trim(),
          token: cached.token,
        );
        PushLog.debug('removed push token for $userId on sign-out');
      } catch (e) {
        PushLog.debug('removing the push token on sign-out failed: $e');
      }
    }
    await unsubscribeAll();
    reset();
  }

  /// Forgets the session's registration guard (sign-out). The next [register]
  /// does the full flow again.
  void reset() {
    _registeredUserId = null;
    _sessionTopics.clear();
    // The persisted set still describes what this device holds, so drop the
    // in-memory copy and let the next use read it back.
    _knownTopics = null;
  }

  /// Stops listening for rotated tokens. Call from an app that tears its push
  /// layer down (tests, or a full sign-out teardown).
  Future<void> dispose() async {
    await _refreshSubscription?.cancel();
    _refreshSubscription = null;
    _initialization = null;
  }

  /// Topics this session subscribed plus the ones cached from earlier
  /// sessions, loaded once and then maintained in [subscribeToTopic] /
  /// [unsubscribeFromTopics].
  Future<Set<String>> _known() async => _knownTopics ??= <String>{
        ..._sessionTopics,
        ...await _cache.readKnownTopics()
      };

  Future<PushAuthorization> _authorize({
    required bool requestPermissionIfNeeded,
  }) async {
    final current = await _messaging.notificationSettings();
    if (current.allowsPush || !requestPermissionIfNeeded) return current;
    return _requestAuthorization();
  }

  Future<PushAuthorization> _requestAuthorization() async {
    // Android 13+ needs the local-notifications runtime permission for the
    // notification the app renders itself; ask for it alongside the push
    // prompt, once, so the user sees a single decision.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final request = _androidNotificationPermission;
      if (request != null) {
        try {
          await request();
        } catch (e) {
          PushLog.debug(
              'requesting the Android notification permission failed: $e');
        }
      }
    }

    try {
      return await _messaging.requestAuthorization();
    } catch (e) {
      PushLog.debug('requesting push authorization failed: $e');
      return PushAuthorization.notDetermined;
    }
  }

  Future<void> _handleRotatedToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) return;

    await _cache.writeToken(
        PushCachedToken(token: value, provider: PushProvider.fcm));

    final userId = _registeredUserId ?? _sessionUserId?.call();
    if (userId == null || userId.trim().isEmpty) {
      PushLog.debug(
          'rotated push token cached; no session to attach it to yet');
      return;
    }
    try {
      await _store.saveDeviceToken(userId: userId, token: value);
      PushLog.debug('rotated push token saved for $userId');
    } catch (e) {
      PushLog.debug('saving the rotated push token failed: $e');
    }
  }

  /// Reads the token, retrying so a cold start that races the network (or the
  /// APNs handshake on iOS) still ends up registered.
  Future<String?> _fetchTokenWithRetry() async {
    for (var attempt = 1; attempt <= tokenFetchAttempts; attempt++) {
      try {
        final token = await _messaging.fetchToken();
        if (token != null && token.trim().isNotEmpty) return token.trim();
        PushLog.debug('push token unavailable (attempt $attempt/$tokenFetchAttempts)');
      } catch (e) {
        PushLog.debug(
            'push token fetch failed (attempt $attempt/$tokenFetchAttempts): $e');
      }
      if (attempt < tokenFetchAttempts) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    return null;
  }
}
