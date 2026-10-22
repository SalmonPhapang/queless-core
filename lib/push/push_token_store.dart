// ============================================================================
// QUELESS CORE — PUSH TOKEN STORE
//
// One row per (user_id, token) in `public.user_fcm_tokens`, whose primary key
// is exactly that. Upserting on the primary key is what makes push reach a
// user on *every* device they are signed in on: a new device inserts its own
// token row, a rotated token updates only its own row, and other devices'
// rows are never touched.
//
// queless_core deliberately does not depend on supabase (the three apps pin
// different majors), so the store takes the app's own upsert/update calls as
// closures — the table name, the row shape and the timestamp stay shared
// here, which is where the three apps used to drift apart.
// ============================================================================

import 'push_log.dart';

/// `Future<void> upsert(table, row)` — e.g.
/// `(table, row) => SupabaseConfig.client.from(table).upsert(row)`.
typedef PushRowUpsert = Future<void> Function(
  String table,
  Map<String, dynamic> row,
);

/// `Future<void> update(table, values, match)` — e.g.
/// `(table, values, match) => SupabaseConfig.client.from(table).update(values).match(match)`.
typedef PushRowUpdate = Future<void> Function(
  String table,
  Map<String, dynamic> values,
  Map<String, dynamic> match,
);

/// Persists this device's push token for the signed-in user.
abstract class PushTokenStore {
  /// [userId] must be the authenticated user's id (the table's RLS policy is
  /// `user_id = auth.uid()`), never a client-supplied value from elsewhere.
  Future<void> saveDeviceToken({required String userId, required String token});
}

/// The Supabase-backed store every app uses.
class SupabasePushTokenStore implements PushTokenStore {
  SupabasePushTokenStore({
    required PushRowUpsert upsert,
    PushRowUpdate? update,
    this.mirrorLegacyUserColumn = false,
  })  : _upsert = upsert,
        _update = update;

  /// Table holding one row per (user_id, token).
  static const String table = 'user_fcm_tokens';

  /// Legacy single-token column on `public.users`.
  static const String legacyTable = 'users';
  static const String legacyColumn = 'fcm_token';

  final PushRowUpsert _upsert;
  final PushRowUpdate? _update;

  /// Also mirrors the token into `users.fcm_token`.
  ///
  /// That column can only ever describe one device, so it is no longer how
  /// pushes are addressed (the Store app still writes it for older server-side
  /// code that reads it). Off by default: the multi-device table is the
  /// source of truth.
  final bool mirrorLegacyUserColumn;

  @override
  Future<void> saveDeviceToken({
    required String userId,
    required String token,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _upsert(table, {
      'user_id': userId,
      'token': token,
      'updated_at': now,
    });

    final update = _update;
    if (!mirrorLegacyUserColumn || update == null) return;
    try {
      await update(legacyTable, {
        'fcm_token': token,
        'updated_at': now
      }, {
        'id': userId,
      });
    } catch (e) {
      // Best-effort: the row that actually delivers pushes is already written.
      PushLog.debug('mirroring $legacyTable.$legacyColumn failed: $e');
    }
  }
}

/// A token [InMemoryPushTokenStore] recorded, for assertions and diagnostics.
class SavedPushToken {
  const SavedPushToken({required this.userId, required this.token});

  final String userId;
  final String token;

  @override
  String toString() => 'SavedPushToken($userId, $token)';
}

/// Non-persistent store: tests, and any build that wants registration to be a
/// no-op without changing the caller.
class InMemoryPushTokenStore implements PushTokenStore {
  final List<SavedPushToken> saved = <SavedPushToken>[];

  bool get isEmpty => saved.isEmpty;

  /// The most recently saved token for [userId], or null.
  String? tokenFor(String userId) {
    for (final row in saved.reversed) {
      if (row.userId == userId) return row.token;
    }
    return null;
  }

  @override
  Future<void> saveDeviceToken({
    required String userId,
    required String token,
  }) async {
    saved.add(SavedPushToken(userId: userId, token: token));
  }
}
