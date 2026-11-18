// ==============================================================================
// QUELESS CORE — PUSH MESSAGING SEAM
//
// The Customer, Driver and Store apps each used to hand-roll the same push
// registration logic. The mechanics (permission policy, token retry + cache,
// per-device token rows, topic set-diff) now live once in [PushRegistrar];
// this file defines the thin seam it talks to, so the registrar can be tested
// without any push SDK and each app only supplies the SDK plumbing that is
// genuinely different (Firebase Cloud Messaging everywhere).
//
// See [FirebasePushMessaging] for the shared FCM implementation.
// ==============================================================================

/// Which push backend a device token was issued by.
///
/// The label is what gets cached on the device (the `user_fcm_tokens` table
/// has no provider column, so the provider is device-local bookkeeping used
/// for diagnostics).
enum PushProvider {
  fcm('fcm'),
  hms('hms');

  const PushProvider(this.label);

  final String label;

  static PushProvider fromLabel(String? label) {
    final value = (label ?? '').toLowerCase().trim();
    if (value == 'hms') return PushProvider.hms;
    return PushProvider.fcm;
  }
}

/// The OS-level answer to "may this app post notifications?".
///
/// This is deliberately *not* firebase_messaging's `AuthorizationStatus`: the
/// registrar owns the policy (see [allowsPush]) and the FCM adapter maps the
/// SDK enum onto it, so a change in the SDK enum can never silently change
/// what the apps consider "authorised".
enum PushAuthorization {
  /// The user has never been asked (iOS/macOS, Android 13+).
  notDetermined,

  /// The user said no, or notifications are disabled for the app.
  denied,

  /// The user granted notifications.
  authorized,

  /// iOS provisional authorization: delivered quietly to the notification
  /// centre. The apps treat this as granted (see [allowsPush]).
  provisional;

  /// Whether pushes may be delivered in this state.
  bool get allowsPush =>
      this == PushAuthorization.authorized ||
      this == PushAuthorization.provisional;
}

/// The small surface [PushRegistrar] needs from a push SDK.
///
/// Implementations must never throw for a missing/denied/undecided
/// permission: they return a [PushAuthorization] instead. Failures inside a
/// single call should be logged and degrade to null/empty, because
/// registration runs on the startup path.
abstract class PushMessaging {
  /// Backend these tokens belong to.
  PushProvider get provider;

  /// Brings the backend up (e.g. `Firebase.initializeApp()`) and reports
  /// whether push is usable at all in this build/platform. Called once by the
  /// registrar, and its answer is memoized there.
  Future<bool> initialize();

  /// Passive read of the current authorization — never prompts.
  Future<PushAuthorization> notificationSettings();

  /// Prompts the user (no-op once the OS answer is already decided).
  Future<PushAuthorization> requestAuthorization();

  /// The current device token, or null when one is not available yet.
  Future<String?> fetchToken();

  /// Emits every new device token (FCM `onTokenRefresh`).
  Stream<String> get onTokenRefresh;

  /// Whether [fetchToken] can hand back a token synchronously.
  ///
  /// Always true for FCM; kept so the seam can express stream-only providers
  /// without changing the registrar flow.
  bool get tokenArrivesOnRefreshStream => false;

  Future<void> subscribeToTopic(String topic);

  Future<void> unsubscribeFromTopic(String topic);
}
