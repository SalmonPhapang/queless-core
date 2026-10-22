// ==============================================================================
// QUELESS CORE — PUSH STATE CACHE
//
// Device-local push state: the last token seen, which provider issued it, and
// the set of FCM topics this device is believed to be subscribed to.
//
// The token cache is not an optimisation. On a cold start `getToken()` can
// resolve before the session is restored, or lose the race with the network /
// the APNs handshake, so the token used to be dropped and the stored row went
// stale until the next launch. Caching it here means the row is refreshed from
// the cached value instead.
//
// The topic set is what lets a *replace* sync (e.g. the Store app's "these are
// the stores I own") unsubscribe topics that were subscribed in an earlier
// process: without it, a store the owner no longer owns keeps sending pushes
// forever, because the in-memory set starts empty on every launch.
// ==============================================================================

import 'package:shared_preferences/shared_preferences.dart';

import 'push_log.dart';
import 'push_messaging.dart';

/// A device token plus the backend it came from.
class PushCachedToken {
  const PushCachedToken({required this.token, this.provider = PushProvider.fcm});

  final String token;
  final PushProvider provider;

  @override
  String toString() => 'PushCachedToken(${provider.label}, $token)';
}

abstract class PushStateCache {
  Future<PushCachedToken?> readToken();

  Future<void> writeToken(PushCachedToken token);

  Future<Set<String>> readKnownTopics();

  Future<void> writeKnownTopics(Set<String> topics);
}

/// shared_preferences-backed cache — the production implementation.
class SharedPreferencesPushStateCache implements PushStateCache {
  static const String tokenKey = 'queless_push_token';
  static const String providerKey = 'queless_push_provider';
  static const String topicsKey = 'queless_push_topics';

  /// Keys written by app builds from before the shared implementation landed
  /// (`push_token` / `push_token_type` in the Customer app, `fcm_token` in the
  /// Driver app). Read so an upgrade keeps the token a cold start may not be
  /// able to fetch again; only the canonical keys are written.
  ///
  /// The legacy `push_token_type` value could be `hms`; the Customer app no
  /// longer supports HMS (that implementation was removed because it caused the
  /// Shorebird release to crash), so the shared push layer targets FCM-only
  /// devices and any cached legacy HMS token is treated as FCM-typed for
  /// registration purposes.
  static const List<String> legacyTokenKeys = <String>[
    'push_token',
    'fcm_token'
  ];
  static const String legacyProviderKey = 'push_token_type';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<PushCachedToken?> readToken() async {
    try {
      final prefs = await _prefs;
      var token = prefs.getString(tokenKey);
      token ??= _firstNonEmpty(
        legacyTokenKeys.map(prefs.getString),
      );
      if (token == null || token.trim().isEmpty) return null;
      return PushCachedToken(token: token);
    } catch (e) {
      PushLog.debug('reading the cached push token failed: $e');
      return null;
    }
  }

  @override
  Future<void> writeToken(PushCachedToken token) async {
    try {
      final prefs = await _prefs;
      await prefs.setString(tokenKey, token.token);
      await prefs.setString(providerKey, token.provider.label);
    } catch (e) {
      PushLog.debug('caching the push token failed: $e');
    }
  }

  @override
  Future<Set<String>> readKnownTopics() async {
    try {
      final prefs = await _prefs;
      return (prefs.getStringList(topicsKey) ?? const <String>[]).toSet();
    } catch (e) {
      PushLog.debug('reading subscribed push topics failed: $e');
      return <String>{};
    }
  }

  @override
  Future<void> writeKnownTopics(Set<String> topics) async {
    try {
      final prefs = await _prefs;
      await prefs.setStringList(topicsKey, topics.toList()..sort());
    } catch (e) {
      PushLog.debug('saving subscribed push topics failed: $e');
    }
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }
}

/// Volatile cache: tests, and builds that should keep nothing on the device.
class InMemoryPushStateCache implements PushStateCache {
  InMemoryPushStateCache({PushCachedToken? token, Set<String>? topics})
      : _token = token,
        _topics = {...?topics};

  PushCachedToken? _token;
  Set<String> _topics;

  /// Writes are visible, which is what a test asserts against.
  PushCachedToken? get token => _token;
  Set<String> get topics => Set<String>.unmodifiable(_topics);

  @override
  Future<PushCachedToken?> readToken() async => _token;

  @override
  Future<void> writeToken(PushCachedToken token) async => _token = token;

  @override
  Future<Set<String>> readKnownTopics() async => Set<String>.from(_topics);

  @override
  Future<void> writeKnownTopics(Set<String> topics) async =>
      _topics = Set<String>.from(topics);
}
