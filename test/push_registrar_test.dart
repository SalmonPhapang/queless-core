import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queless_core/queless_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every SDK call the registrar makes, so the policy (what it asks
/// for, in which order, and what it skips) can be asserted without any push
/// SDK or Supabase.
class FakePushMessaging implements PushMessaging {
  FakePushMessaging({
    this.provider = PushProvider.fcm,
    this.supported = true,
    this.authorization = PushAuthorization.authorized,
    this.promptResult = PushAuthorization.authorized,
    this.token = 'token-1',
    this.tokenArrivesOnRefreshStream = false,
    this.tokenError,
  });

  @override
  final PushProvider provider;

  @override
  final bool tokenArrivesOnRefreshStream;

  final bool supported;

  /// Answer of the passive read.
  PushAuthorization authorization;

  /// Answer of the prompt.
  final PushAuthorization promptResult;

  String? token;
  Object? tokenError;

  int initializeCalls = 0;
  int fetchTokenCalls = 0;
  int promptCalls = 0;
  final List<String> subscribed = <String>[];
  final List<String> unsubscribed = <String>[];

  final StreamController<String> _refresh =
      StreamController<String>.broadcast();

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return supported;
  }

  @override
  Future<PushAuthorization> notificationSettings() async => authorization;

  @override
  Future<PushAuthorization> requestAuthorization() async {
    promptCalls++;
    authorization = promptResult;
    return promptResult;
  }

  @override
  Future<String?> fetchToken() async {
    fetchTokenCalls++;
    final error = tokenError;
    if (error != null) throw error;
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => _refresh.stream;

  @override
  Future<void> subscribeToTopic(String topic) async => subscribed.add(topic);

  @override
  Future<void> unsubscribeFromTopic(String topic) async =>
      unsubscribed.add(topic);

  void emitToken(String value) => _refresh.add(value);

  Future<void> close() => _refresh.close();
}

void main() {
  late FakePushMessaging messaging;
  late InMemoryPushTokenStore store;
  late InMemoryPushStateCache cache;
  String? sessionUserId;
  late int androidPermissionRequests;

  PushRegistrar buildRegistrar() => PushRegistrar(
        messaging: messaging,
        store: store,
        cache: cache,
        sessionUserId: () => sessionUserId,
        requestAndroidNotificationPermission: () async =>
            androidPermissionRequests++,
        tokenFetchAttempts: 1,
      );

  setUp(() {
    messaging = FakePushMessaging();
    store = InMemoryPushTokenStore();
    cache = InMemoryPushStateCache();
    sessionUserId = 'user-1';
    androidPermissionRequests = 0;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await messaging.close();
  });

  test('registers the session user: caches the token and writes one row',
      () async {
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(result.isRegistered, isTrue);
    expect(store.saved.single.userId, 'user-1');
    expect(store.saved.single.token, 'token-1');
    expect(cache.token?.token, 'token-1');
    expect(cache.token?.provider, PushProvider.fcm);
    expect(registrar.registeredUserId, 'user-1');
  });

  test('reports noSession and writes nothing without a signed-in user',
      () async {
    sessionUserId = null;
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.noSession);
    expect(store.isEmpty, isTrue);
    expect(messaging.fetchTokenCalls, 0);
  });

  test('does nothing at all when the platform cannot do push', () async {
    messaging = FakePushMessaging(supported: false);
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.unsupported);
    expect(messaging.fetchTokenCalls, 0);
    expect(store.isEmpty, isTrue);
  });

  test('skips the repeat work inside one session, unless forced', () async {
    final registrar = buildRegistrar();

    await registrar.register();
    final rowsAfterFirst = store.saved.length;
    final second = await registrar.register();
    final rowsAfterSecond = store.saved.length;
    final forced = await registrar.register(force: true);

    expect(rowsAfterFirst, 1);
    expect(second.outcome, PushRegistrationOutcome.alreadyRegistered);
    expect(second.isRegistered, isTrue);
    // The repeat was skipped, not repeated...
    expect(rowsAfterSecond, 1);
    // ...and forcing one writes exactly one more row.
    expect(forced.outcome, PushRegistrationOutcome.registered);
    expect(store.saved.length, 2);
  });

  test('never writes a token row while notifications are denied', () async {
    messaging = FakePushMessaging(authorization: PushAuthorization.denied);
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.permissionDenied);
    expect(store.isEmpty, isTrue);
    // The token is still cached, so a later grant publishes it immediately.
    expect(cache.token?.token, 'token-1');
    expect(registrar.isRegistered, isFalse);
  });

  test('prompts once when asked, including the Android 13 hook', () async {
    messaging = FakePushMessaging(
      authorization: PushAuthorization.notDetermined,
      promptResult: PushAuthorization.authorized,
    );
    final registrar = buildRegistrar();

    final result = await registrar.register(requestPermissionIfNeeded: true);

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(messaging.promptCalls, 1);
    expect(androidPermissionRequests, 1);
    expect(store.saved.single.token, 'token-1');
  });

  test('treats provisional authorization as granted', () async {
    messaging = FakePushMessaging(authorization: PushAuthorization.provisional);
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(messaging.promptCalls, 0);
  });

  test('does not prompt when the caller forbids it', () async {
    messaging =
        FakePushMessaging(authorization: PushAuthorization.notDetermined);
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.permissionDenied);
    expect(messaging.promptCalls, 0);
    expect(androidPermissionRequests, 0);
    expect(store.isEmpty, isTrue);
  });

  test('uses a cached token when the device has none fresh', () async {
    messaging = FakePushMessaging(token: null);
    cache = InMemoryPushStateCache(
      token: const PushCachedToken(
        token: 'cached-token',
      ),
    );
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(store.saved.single.token, 'cached-token');
    expect(cache.token?.token, 'cached-token');
  });

  test('reports noToken and stays unregistered when nothing is available',
      () async {
    messaging = FakePushMessaging(token: null);
    final registrar = buildRegistrar();

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.noToken);
    expect(store.isEmpty, isTrue);
    expect(registrar.isRegistered, isFalse);
  });

  test('reports saveFailed and can retry when Supabase rejects the row',
      () async {
    final registrar = buildRegistrar();
    // A store that fails once, then succeeds.
    final failing = _FailingStore();

    final result = await PushRegistrar(
      messaging: messaging,
      store: failing,
      cache: cache,
      sessionUserId: () => sessionUserId,
      tokenFetchAttempts: 1,
    ).register();

    expect(result.outcome, PushRegistrationOutcome.saveFailed);
    expect(result.error, isNotNull);

    final retry = await registrar.register();
    expect(retry.outcome, PushRegistrationOutcome.registered);
  });

  test('saves a rotated token for the signed-in user and caches it', () async {
    final registrar = buildRegistrar();
    await registrar.register();
    await registrar.attachTokenRefreshListener();

    messaging.emitToken('token-2');
    await pumpEventQueue();

    expect(cache.token?.token, 'token-2');
    expect(store.saved.last.token, 'token-2');
    expect(store.saved.last.userId, 'user-1');
  });

  test('attaches a rotated token that arrived before a session existed',
      () async {
    sessionUserId = null;
    final registrar = buildRegistrar();
    await registrar.attachTokenRefreshListener();

    messaging.emitToken('token-3');
    await pumpEventQueue();
    expect(cache.token?.token, 'token-3');
    expect(store.isEmpty, isTrue);

    // Session restored on a later launch/foreground: the row is written then.
    sessionUserId = 'user-1';
    messaging.token = null;
    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(store.saved.single.token, 'token-3');
  });

  test('subscribes the requested topics on a merge sync', () async {
    final registrar = buildRegistrar();

    await registrar.register(
      topics: [PushTopics.driverOrdersReady, PushTopics.driver('drv-1')],
    );

    expect(
      messaging.subscribed.toSet(),
      {'DRIVER_ORDERS_READY', 'driver-drv-1'},
    );
    expect(cache.topics, {'DRIVER_ORDERS_READY', 'driver-drv-1'});
    expect(messaging.unsubscribed, isEmpty);
  });

  test('a replace sync drops stale topics from an earlier session', () async {
    cache = InMemoryPushStateCache(topics: {'store-old', 'marketing'});
    final registrar = buildRegistrar();

    await registrar.syncTopics(['store-new', 'marketing'], replaceTopics: true);

    expect(messaging.subscribed, containsAll(['store-new', 'marketing']));
    expect(messaging.unsubscribed, ['store-old']);
    expect(cache.topics, {'store-new', 'marketing'});
  });

  test('ignores malformed topic names instead of failing the sync', () async {
    final registrar = buildRegistrar();

    final subscribed = await registrar.syncTopics(
      ['order-QLE-1A2B3C4D', 'not a topic', '   '],
      replaceTopics: true,
    );

    expect(subscribed, {'order-QLE-1A2B3C4D'});
    expect(messaging.subscribed, ['order-QLE-1A2B3C4D']);
  });

  test('unsubscribeAll drops this session and earlier subscriptions', () async {
    cache = InMemoryPushStateCache(topics: {'store-a'});
    final registrar = buildRegistrar();
    await registrar.subscribeToTopic('store-b');

    await registrar.unsubscribeAll();

    expect(messaging.unsubscribed.toSet(), {'store-a', 'store-b'});
    expect(cache.topics, isEmpty);
  });

  test('reset() forgets the session so the next register runs again', () async {
    final registrar = buildRegistrar();
    await registrar.register();

    registrar.reset();
    expect(registrar.registeredUserId, isNull);
    expect(registrar.isRegistered, isFalse);

    final result = await registrar.register();

    expect(result.outcome, PushRegistrationOutcome.registered);
    expect(registrar.registeredUserId, 'user-1');
  });

  group('SharedPreferencesPushStateCache', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('round-trips the token and topics', () async {
      final prefs = SharedPreferencesPushStateCache();

      await prefs.writeToken(
        const PushCachedToken(token: 'abc'),
      );
      await prefs.writeKnownTopics({'order-1'});

      final token = await prefs.readToken();
      expect(token?.token, 'abc');
      expect(token?.provider, PushProvider.fcm);
      expect(await prefs.readKnownTopics(), {'order-1'});
    });

    test('reads the token written by a pre-shared-implementation build',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'push_token': 'legacy-token',
        'push_token_type': 'hms',
      });
      final prefs = SharedPreferencesPushStateCache();

      final token = await prefs.readToken();

      expect(token?.token, 'legacy-token');
      // The Customer app no longer supports HMS — that implementation was
      // removed because it caused the Shorebird release to crash — so the
      // shared push layer targets FCM-only devices and any legacy HMS-typed
      // cached token is treated as FCM for registration purposes.
      expect(token?.provider, PushProvider.fcm);
    });

    test('falls back to the driver app\'s legacy key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fcm_token': 'driver-legacy',
      });
      final prefs = SharedPreferencesPushStateCache();

      final token = await prefs.readToken();

      expect(token?.token, 'driver-legacy');
      expect(token?.provider, PushProvider.fcm);
    });

    test('returns null when nothing was ever cached', () async {
      expect(await SharedPreferencesPushStateCache().readToken(), isNull);
      expect(
        await SharedPreferencesPushStateCache().readKnownTopics(),
        isEmpty,
      );
    });
  });

  group('PushCachedToken defaults', () {
    test('defaults the provider to FCM when none is supplied', () async {
      const cached = PushCachedToken(token: 'tok');
      expect(cached.provider, PushProvider.fcm);
      expect(cached.token, 'tok');
    });
  });

  group('SupabasePushTokenStore', () {
    test('writes the multi-device row and mirrors the legacy column on demand',
        () async {
      final upserts = <String, Map<String, dynamic>>{};
      final updates = <String, Map<String, dynamic>>{};
      final store = SupabasePushTokenStore(
        upsert: (table, row) async => upserts[table] = row,
        update: (table, values, match) async => updates[table] = {
          ...values,
          ...match,
        },
        mirrorLegacyUserColumn: true,
      );

      await store.saveDeviceToken(userId: 'user-1', token: 'tok');

      expect(upserts.keys, {SupabasePushTokenStore.table});
      expect(upserts[SupabasePushTokenStore.table]!['user_id'], 'user-1');
      expect(upserts[SupabasePushTokenStore.table]!['token'], 'tok');
      expect(
        updates[SupabasePushTokenStore.legacyTable],
        containsPair('fcm_token', 'tok'),
      );
    });

    test('does not mirror the legacy column by default', () async {
      var updates = 0;
      final store = SupabasePushTokenStore(
        upsert: (table, row) async {},
        update: (table, values, match) async => updates++,
      );

      await store.saveDeviceToken(userId: 'user-1', token: 'tok');

      expect(updates, 0);
    });

    test('a failing legacy mirror does not fail registration', () async {
      final store = SupabasePushTokenStore(
        upsert: (table, row) async {},
        update: (table, values, match) async => throw StateError('no column'),
        mirrorLegacyUserColumn: true,
      );

      await expectLater(
        store.saveDeviceToken(userId: 'user-1', token: 'tok'),
        completes,
      );
    });

    test('derives the cached token for a stream-only provider from the cache',
        () async {
      messaging = FakePushMessaging(
        token: null,
        tokenArrivesOnRefreshStream: true,
      );
      cache = InMemoryPushStateCache(
        token: const PushCachedToken(token: 'cached-stream-token'),
      );
      final registrar = buildRegistrar();

      final result = await registrar.register();

      expect(result.outcome, PushRegistrationOutcome.registered);
      expect(store.saved.single.token, 'cached-stream-token');
    });
  });

  group('PushTopics', () {
    test('builds every topic name the ecosystem publishes to', () {
      expect(PushTopics.order('QLE-1A2B3C4D'), 'order-QLE-1A2B3C4D');
      expect(PushTopics.store('store-uuid'), 'store-store-uuid');
      expect(PushTopics.driver('driver-uuid'), 'driver-driver-uuid');
      expect(PushTopics.marketing, 'marketing');
      expect(PushTopics.driverOrdersReady, 'DRIVER_ORDERS_READY');
    });

    test('rejects names FCM would refuse', () {
      expect(PushTopics.isValid('order-1'), isTrue);
      expect(PushTopics.isValid('order 1'), isFalse);
      expect(PushTopics.isValid(''), isFalse);
      expect(
          PushTopics.normalize(
            [' ok-1 ', 'bad/topic', ''],
          ),
          {'ok-1'});
    });
  });
}

class _FailingStore implements PushTokenStore {
  @override
  Future<void> saveDeviceToken({
    required String userId,
    required String token,
  }) async {
    throw StateError('RLS: not authenticated');
  }
}
