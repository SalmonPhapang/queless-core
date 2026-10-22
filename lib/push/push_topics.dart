// ============================================================================
// QUELESS CORE — PUSH TOPIC NAMES
//
// Every topic name the Queless ecosystem publishes to is built here, so the
// Customer, Driver and Store apps cannot drift apart on spelling (a topic both
// sides must agree on, where a typo silently means "no pushes").
//
// Topic names must match [a-zA-Z0-9-_.~%]+ — an order number or id that does
// not is rejected rather than sent to the SDK ([isValid]), because FCM throws
// on a malformed topic and one bad subscription used to abort the rest of a
// sync.
// ============================================================================

import 'push_log.dart';

class PushTopics {
  /// Marketing/broadcast topic subscribed by the customer and store apps.
  static const String marketing = 'marketing';

  /// The single topic every on-duty driver listens on for new orders.
  static const String driverOrdersReady = 'DRIVER_ORDERS_READY';

  /// Per-order topic (customer and driver apps), keyed by the human-readable
  /// order number so it is stable across all three apps.
  static String order(String orderNumber) => 'order-${orderNumber.trim()}';

  /// Per-store topic (store app), keyed by store id.
  static String store(String storeId) => 'store-${storeId.trim()}';

  /// Per-driver topic (driver app), keyed by user id.
  static String driver(String driverId) => 'driver-${driverId.trim()}';

  static final RegExp _valid = RegExp(r'^[a-zA-Z0-9\-_.~%]+$');

  /// Whether FCM accepts [topic] (trimmed). Empty and whitespace-only names
  /// are invalid.
  static bool isValid(String topic) => _valid.hasMatch(topic.trim());

  /// Trims, drops blanks and rejects names FCM would refuse — the set-diff
  /// engine works on the result.
  static Set<String> normalize(Iterable<String> topics) {
    final wanted = <String>{};
    for (final topic in topics) {
      final trimmed = topic.trim();
      if (trimmed.isEmpty) continue;
      if (!isValid(trimmed)) {
        PushLog.debug('ignoring invalid push topic "$topic"');
        continue;
      }
      wanted.add(trimmed);
    }
    return wanted;
  }
}
