import 'package:flutter/material.dart';

// ============================================================================
// QUELESS CORE — UNIFIED STATUS SYSTEM — SINGLE SOURCE OF TRUTH
//
// This is the canonical status system shared by the Customer App, Driver App,
// and Store App. The three apps used to carry three hand-copied copies of
// this file that drifted apart (different enum members, different extension
// names, different parse helpers). That duplication is now dead: each app's
// local `models/statuses.dart` is a one-line `export` of this file.
//
// Rules:
//  - databaseValue  -> snake_case string (what is stored in Supabase)
//  - displayName    -> human-readable string
//  - color/icon     -> UI hints consistent across all apps
//  - allowedNext    -> allowed state transitions (finite state machine)
//  - isTerminal     -> no further updates allowed
////  BACKWARD-COMPAT ALIASES:
//  The driver app historically called OrderStatusX.fromDatabaseValue(...),
//  the store app called OrderStatusExt.fromDatabaseValue(...). Both patterns
//  are preserved via extension aliases at the bottom of this file, so old
//  call sites keep compiling untouched.
//
//  INTENTIONAL BEHAVIORAL UNIFICATIONS (vs the old per-app copies):
//  - OrderStatus.isActive is now `!isTerminal` (the driver app's old copy
//    also excluded pending/awaitingPayment; no driver call sites relied on it).
//  - StoreStatus.acceptsOrders is now {open, busy} (driver/store old copies
//    were open-only; no call sites relied on it).
//
//  UNION ENUMS — DO NOT ITERATE .values FOR UI:
//  DriverStatus (5 members) and OrderAcceptanceStatus (10 members) are unions
//  of the three apps' divergent dialects, so `DriverStatus.values` /
//  `OrderAcceptanceStatus.values` contain members other apps may not use.
//  App code must enumerate explicit members, never `.values`, for these two.
// ============================================================================

// ============================================================================
// 1. ORDER LIFECYCLE — VISIBLE TO USER / DRIVER / STORE
// ============================================================================
enum OrderStatus {
  /// User just placed order, awaiting store to acknowledge receipt.
  pending,

  /// Manual/EFT orders: user still needs to pay.
  awaitingPayment,

  /// Store received order, must now accept or reject it.
  awaitingStoreAcceptance,

  /// Store accepted the order, preparing/packing items.
  preparing,

  /// Store has packed the order and is waiting for a driver to collect.
  readyForPickup,

  /// Driver has been assigned the order but hasn't collected yet.
  driverAssigned,

  /// Driver has collected the order and is en route to customer.
  outForDelivery,

  /// Driver arrived at location, attempting handoff / waiting for customer.
  arrived,

  /// Order successfully handed over to the customer.
  delivered,

  /// Customer cancelled the order (allowed before driver collects).
  cancelled,

  /// Store rejected the order (out of stock, cannot fulfill).
  rejected,

  /// Driver was unable to deliver (no answer, wrong address, etc.)
  failedDelivery,

  /// Order was refunded after delivery or during processing.
  refunded;

  /// Value stored in the database (snake_case, identical across all apps).
  /// Matches what the edge functions (paystack-webhook, verify-paystack-split)
  /// write to the `orders.status` column.
  String get databaseValue {
    switch (this) {
      case OrderStatus.pending:
        return 'pending';
      case OrderStatus.awaitingPayment:
        return 'awaiting_payment';
      case OrderStatus.awaitingStoreAcceptance:
        return 'awaiting_store_acceptance';
      case OrderStatus.preparing:
        return 'preparing';
      case OrderStatus.readyForPickup:
        return 'ready_for_pickup';
      case OrderStatus.driverAssigned:
        return 'driver_assigned';
      case OrderStatus.outForDelivery:
        return 'out_for_delivery';
      case OrderStatus.arrived:
        return 'arrived';
      case OrderStatus.delivered:
        return 'delivered';
      case OrderStatus.cancelled:
        return 'cancelled';
      case OrderStatus.rejected:
        return 'rejected';
      case OrderStatus.failedDelivery:
        return 'failed_delivery';
      case OrderStatus.refunded:
        return 'refunded';
    }
  }

  /// User-friendly label displayed in the UI.
  String get displayName {
    switch (this) {
      case OrderStatus.pending:
        return 'Pending';
      case OrderStatus.awaitingPayment:
        return 'Awaiting Payment';
      case OrderStatus.awaitingStoreAcceptance:
        return 'Awaiting Store Acceptance';
      case OrderStatus.preparing:
        return 'Preparing';
      case OrderStatus.readyForPickup:
        return 'Ready for Pickup';
      case OrderStatus.driverAssigned:
        return 'Driver Assigned';
      case OrderStatus.outForDelivery:
        return 'Out for Delivery';
      case OrderStatus.arrived:
        return 'Arrived';
      case OrderStatus.delivered:
        return 'Delivered';
      case OrderStatus.cancelled:
        return 'Cancelled';
      case OrderStatus.rejected:
        return 'Rejected';
      case OrderStatus.failedDelivery:
        return 'Failed Delivery';
      case OrderStatus.refunded:
        return 'Refunded';
    }
  }

  /// Material icon hinting the status (same across all apps).
  IconData get icon {
    switch (this) {
      case OrderStatus.pending:
        return Icons.hourglass_top_rounded;
      case OrderStatus.awaitingPayment:
        return Icons.payments_rounded;
      case OrderStatus.awaitingStoreAcceptance:
        return Icons.storefront_rounded;
      case OrderStatus.preparing:
        return Icons.restaurant_rounded;
      case OrderStatus.readyForPickup:
        return Icons.inventory_2_rounded;
      case OrderStatus.driverAssigned:
        return Icons.person_pin_circle_rounded;
      case OrderStatus.outForDelivery:
        return Icons.delivery_dining_rounded;
      case OrderStatus.arrived:
        return Icons.location_on_rounded;
      case OrderStatus.delivered:
        return Icons.check_circle_rounded;
      case OrderStatus.cancelled:
        return Icons.cancel_rounded;
      case OrderStatus.rejected:
        return Icons.block_rounded;
      case OrderStatus.failedDelivery:
        return Icons.error_rounded;
      case OrderStatus.refunded:
        return Icons.money_off_rounded;
    }
  }

  /// Semantic color used for chips, timelines, badges (same across 3 apps).
  Color get color {
    switch (this) {
      case OrderStatus.pending:
        return Colors.blueGrey;
      case OrderStatus.awaitingPayment:
        return Colors.amber;
      case OrderStatus.awaitingStoreAcceptance:
        return Colors.orange;
      case OrderStatus.preparing:
        return Colors.deepOrange;
      case OrderStatus.readyForPickup:
        return Colors.teal;
      case OrderStatus.driverAssigned:
        return Colors.indigo;
      case OrderStatus.outForDelivery:
        return Colors.blue;
      case OrderStatus.arrived:
        return Colors.cyan;
      case OrderStatus.delivered:
        return Colors.green;
      case OrderStatus.cancelled:
        return Colors.grey;
      case OrderStatus.rejected:
        return Colors.red;
      case OrderStatus.failedDelivery:
        return Colors.brown;
      case OrderStatus.refunded:
        return Colors.purple;
    }
  }

  /// Finite state machine: which statuses you can transition to from here.
  Set<OrderStatus> get allowedNextStatuses {
    switch (this) {
      case OrderStatus.pending:
        return const {
          OrderStatus.awaitingPayment,
          OrderStatus.awaitingStoreAcceptance,
          OrderStatus.cancelled,
        };
      case OrderStatus.awaitingPayment:
        return const {
          OrderStatus.awaitingStoreAcceptance,
          OrderStatus.cancelled,
        };
      case OrderStatus.awaitingStoreAcceptance:
        return const {
          OrderStatus.preparing,
          OrderStatus.rejected,
          OrderStatus.cancelled,
        };
      case OrderStatus.preparing:
        return const {
          OrderStatus.readyForPickup,
          OrderStatus.cancelled,
          OrderStatus.refunded,
        };
      case OrderStatus.readyForPickup:
        return const {
          OrderStatus.driverAssigned,
          OrderStatus.cancelled,
        };
      case OrderStatus.driverAssigned:
        return const {
          OrderStatus.outForDelivery,
          OrderStatus.cancelled,
        };
      case OrderStatus.outForDelivery:
        return const {
          OrderStatus.arrived,
          OrderStatus.failedDelivery,
        };
      case OrderStatus.arrived:
        return const {
          OrderStatus.delivered,
          OrderStatus.failedDelivery,
        };
      case OrderStatus.delivered:
        return const {
          OrderStatus.refunded,
        };
      case OrderStatus.cancelled:
      case OrderStatus.rejected:
      case OrderStatus.failedDelivery:
      case OrderStatus.refunded:
        return const {};
    }
  }

  /// True if no further status changes are expected.
  bool get isTerminal {
    return const {
      OrderStatus.delivered,
      OrderStatus.cancelled,
      OrderStatus.rejected,
      OrderStatus.failedDelivery,
      OrderStatus.refunded,
    }.contains(this);
  }

  /// True if the order is still "in flight" (customer waiting).
  bool get isActive => !isTerminal;

  /// Whether the USER can request cancellation in this state.
  bool get userCanCancel {
    return const {
      OrderStatus.pending,
      OrderStatus.awaitingPayment,
      OrderStatus.awaitingStoreAcceptance,
      OrderStatus.preparing,
      OrderStatus.readyForPickup,
      OrderStatus.driverAssigned,
    }.contains(this);
  }

  /// Whether the STORE can perform actions in this state.
  bool get storeCanUpdate {
    return const {
      OrderStatus.awaitingStoreAcceptance,
      OrderStatus.preparing,
      OrderStatus.readyForPickup,
    }.contains(this);
  }

  /// Whether the DRIVER can perform actions in this state.
  bool get driverCanUpdate {
    return const {
      OrderStatus.driverAssigned,
      OrderStatus.outForDelivery,
      OrderStatus.arrived,
    }.contains(this);
  }

  /// Parse a DB string back into an enum (case-insensitive & lenient).
  ///
  /// Accepts both snake_case (e.g. 'awaiting_payment', which the edge
  /// functions write) and camelCase (e.g. 'awaitingPayment', from older app
  /// versions), plus every legacy alias the three apps historically accepted.
  static OrderStatus fromDatabaseValue(String? value,
      {OrderStatus fallback = OrderStatus.pending}) {
    if (value == null || value.isEmpty) return fallback;
    // Normalize: lowercase and strip separators so both formats match.
    final normalized =
        value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final status in OrderStatus.values) {
      if (status.name.toLowerCase() == normalized) return status;
      if (status.databaseValue.replaceAll(RegExp(r'[^a-z0-9]'), '') ==
          normalized) {
        return status;
      }
    }
    // Backward-compat aliases that don't match any canonical value.
    switch (normalized) {
      case 'confirmed':
        return OrderStatus.awaitingStoreAcceptance;
      case 'delivering':
      case 'enroute':
      case 'ontheway':
      case 'ontheway2':
      case 'on_the_way':
      case 'pickedup':
        return OrderStatus.outForDelivery;
      case 'complete':
      case 'completed':
      case 'success':
        return OrderStatus.delivered;
      case 'canceled':
        return OrderStatus.cancelled;
      case 'assigned':
        return OrderStatus.driverAssigned;
      case 'ready':
        return OrderStatus.readyForPickup;
      case 'in_progress':
      case 'cooking':
        return OrderStatus.preparing;
      case 'at_door':
      case 'customer_location':
        return OrderStatus.arrived;
      case 'declined':
      case 'denied':
        return OrderStatus.rejected;
      case 'failed':
      case 'undelivered':
        return OrderStatus.failedDelivery;
      case 'refund':
        return OrderStatus.refunded;
      case 'aborted':
        return OrderStatus.cancelled;
      default:
        return fallback;
    }
  }
}

// ============================================================================
// 2. PAYMENT LIFECYCLE — VISIBLE TO USER / STORE
// ============================================================================
enum PaymentStatus {
  pending,
  awaitingPayment,
  processing,
  completed,
  failed,
  refunded,
  partiallyRefunded;

  String get databaseValue {
    switch (this) {
      case PaymentStatus.pending:
        return 'pending';
      case PaymentStatus.awaitingPayment:
        return 'awaiting_payment';
      case PaymentStatus.processing:
        return 'processing';
      case PaymentStatus.completed:
        return 'completed';
      case PaymentStatus.failed:
        return 'failed';
      case PaymentStatus.refunded:
        return 'refunded';
      case PaymentStatus.partiallyRefunded:
        return 'partially_refunded';
    }
  }

  String get displayName {
    switch (this) {
      case PaymentStatus.pending:
        return 'Pending';
      case PaymentStatus.awaitingPayment:
        return 'Awaiting Payment';
      case PaymentStatus.processing:
        return 'Processing';
      case PaymentStatus.completed:
        return 'Paid';
      case PaymentStatus.failed:
        return 'Failed';
      case PaymentStatus.refunded:
        return 'Refunded';
      case PaymentStatus.partiallyRefunded:
        return 'Partially Refunded';
    }
  }

  IconData get icon {
    switch (this) {
      case PaymentStatus.pending:
        return Icons.hourglass_empty_rounded;
      case PaymentStatus.awaitingPayment:
        return Icons.payments_rounded;
      case PaymentStatus.processing:
        return Icons.hourglass_bottom_rounded;
      case PaymentStatus.completed:
        return Icons.check_circle_rounded;
      case PaymentStatus.failed:
        return Icons.error_rounded;
      case PaymentStatus.refunded:
      case PaymentStatus.partiallyRefunded:
        return Icons.money_off_rounded;
    }
  }

  Color get color {
    switch (this) {
      case PaymentStatus.pending:
      case PaymentStatus.awaitingPayment:
        return Colors.orange;
      case PaymentStatus.processing:
        return Colors.blue;
      case PaymentStatus.completed:
        return Colors.green;
      case PaymentStatus.failed:
        return Colors.red;
      case PaymentStatus.refunded:
      case PaymentStatus.partiallyRefunded:
        return Colors.purple;
    }
  }

  /// Finite state machine (used by the driver app's order service).
  Set<PaymentStatus> get allowedNextStatuses {
    switch (this) {
      case PaymentStatus.pending:
        return const {
          PaymentStatus.awaitingPayment,
          PaymentStatus.processing,
          PaymentStatus.completed,
          PaymentStatus.failed,
        };
      case PaymentStatus.awaitingPayment:
        return const {
          PaymentStatus.completed,
          PaymentStatus.failed,
        };
      case PaymentStatus.processing:
        return const {
          PaymentStatus.completed,
          PaymentStatus.failed,
        };
      case PaymentStatus.completed:
        return const {
          PaymentStatus.refunded,
          PaymentStatus.partiallyRefunded,
        };
      case PaymentStatus.failed:
        return const {};
      case PaymentStatus.refunded:
      case PaymentStatus.partiallyRefunded:
        return const {};
    }
  }

  bool get isTerminal {
    return const {
      PaymentStatus.completed,
      PaymentStatus.failed,
      PaymentStatus.refunded,
      PaymentStatus.partiallyRefunded,
    }.contains(this);
  }

  bool get isPaid =>
      this == PaymentStatus.completed ||
      this == PaymentStatus.partiallyRefunded;

  static PaymentStatus fromDatabaseValue(String? value,
      {PaymentStatus fallback = PaymentStatus.pending}) {
    if (value == null || value.isEmpty) return fallback;
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    switch (normalized) {
      case 'pending':
      case 'unpaid':
        return PaymentStatus.pending;
      case 'awaiting_payment':
      case 'awaitingpayment':
      case 'payment_pending':
        return PaymentStatus.awaitingPayment;
      case 'processing':
      case 'in_progress':
        return PaymentStatus.processing;
      case 'completed':
      case 'complete':
      case 'success':
      case 'succeeded':
      case 'paid':
      case 'captured':
        return PaymentStatus.completed;
      case 'failed':
      case 'failure':
      case 'declined':
      case 'error':
        return PaymentStatus.failed;
      case 'refunded':
      case 'reversed':
      case 'refund':
        return PaymentStatus.refunded;
      case 'partially_refunded':
      case 'partial':
        return PaymentStatus.partiallyRefunded;
      default:
        return fallback;
    }
  }
}

// ============================================================================
// 3. DRIVER LIFECYCLE — DRIVER APP ONLY
// ============================================================================
enum DriverStatus {
  /// Driver is signed out / not taking any orders.
  offline,

  /// Driver is online and waiting for orders.
  online,

  /// Driver is currently fulfilling an order (cannot take new ones).
  onDelivery,

  /// Driver is on a break, not receiving new orders.
  onBreak,

  /// Driver is inactive/disabled (legacy alias used by the driver app).
  inactive;

  String get databaseValue {
    switch (this) {
      case DriverStatus.offline:
        return 'offline';
      case DriverStatus.online:
        return 'online';
      case DriverStatus.onDelivery:
        return 'on_delivery';
      case DriverStatus.onBreak:
        return 'on_break';
      case DriverStatus.inactive:
        return 'inactive';
    }
  }

  String get displayName {
    switch (this) {
      case DriverStatus.offline:
        return 'Offline';
      case DriverStatus.online:
        return 'Online';
      case DriverStatus.onDelivery:
        return 'On Delivery';
      case DriverStatus.onBreak:
        return 'On Break';
      case DriverStatus.inactive:
        return 'Inactive';
    }
  }

  IconData get icon {
    switch (this) {
      case DriverStatus.offline:
        return Icons.cloud_off_rounded;
      case DriverStatus.online:
        return Icons.cloud_done_rounded;
      case DriverStatus.onDelivery:
        return Icons.delivery_dining_rounded;
      case DriverStatus.onBreak:
        return Icons.local_cafe_rounded;
      case DriverStatus.inactive:
        return Icons.do_not_disturb_rounded;
    }
  }

  Color get color {
    switch (this) {
      case DriverStatus.offline:
        return Colors.grey;
      case DriverStatus.online:
        return Colors.green;
      case DriverStatus.onDelivery:
        return Colors.blue;
      case DriverStatus.onBreak:
        return Colors.amber;
      case DriverStatus.inactive:
        return Colors.red;
    }
  }

  /// Can driver receive new orders?
  bool get canReceiveOrders => this == DriverStatus.online;

  Set<DriverStatus> get allowedNextStatuses {
    switch (this) {
      case DriverStatus.offline:
        return const {DriverStatus.online, DriverStatus.onBreak};
      case DriverStatus.online:
        return const {
          DriverStatus.offline,
          DriverStatus.onBreak,
          DriverStatus.onDelivery,
        };
      case DriverStatus.onDelivery:
        return const {DriverStatus.online, DriverStatus.offline};
      case DriverStatus.onBreak:
        return const {DriverStatus.online, DriverStatus.offline};
      case DriverStatus.inactive:
        return const {DriverStatus.offline, DriverStatus.online};
    }
  }

  static DriverStatus fromDatabaseValue(String? value,
      {DriverStatus fallback = DriverStatus.offline}) {
    if (value == null || value.isEmpty) return fallback;
    final lower = value.trim().toLowerCase().replaceAll('-', '_');
    switch (lower) {
      case 'active':
      case 'available':
        return DriverStatus.online;
      case 'unavailable':
        return DriverStatus.offline;
      case 'busy':
      case 'delivering':
        return DriverStatus.onDelivery;
      case 'on_break':
      case 'break':
        return DriverStatus.onBreak;
      case 'banned':
      case 'disabled':
        return DriverStatus.inactive;
    }
    return DriverStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == lower || e.databaseValue == lower,
      orElse: () => fallback,
    );
  }
}

// ============================================================================
// 4. STORE LIFECYCLE — STORE APP ONLY
// ============================================================================
enum StoreStatus {
  /// Store is open & accepting orders normally.
  open,

  /// Store is closed for the day / off-hours.
  closed,

  /// Store is open but swamped, may reject new orders (UX: warning).
  busy,

  /// Store closed temporarily (e.g. load shedding, stock check).
  temporarilyClosed,

  /// Store is disabled by admin or signed out, not taking any orders.
  offline;

  String get databaseValue => name;

  String get displayName {
    switch (this) {
      case StoreStatus.open:
        return 'Open';
      case StoreStatus.closed:
        return 'Closed';
      case StoreStatus.busy:
        return 'Busy';
      case StoreStatus.temporarilyClosed:
        return 'Temporarily Closed';
      case StoreStatus.offline:
        return 'Offline';
    }
  }

  IconData get icon {
    switch (this) {
      case StoreStatus.open:
        return Icons.store_mall_directory_rounded;
      case StoreStatus.closed:
        return Icons.store_rounded;
      case StoreStatus.busy:
        return Icons.local_fire_department_rounded;
      case StoreStatus.temporarilyClosed:
        return Icons.warning_rounded;
      case StoreStatus.offline:
        return Icons.cloud_off_rounded;
    }
  }

  Color get color {
    switch (this) {
      case StoreStatus.open:
        return Colors.green;
      case StoreStatus.busy:
        return Colors.amber;
      case StoreStatus.closed:
      case StoreStatus.offline:
        return Colors.grey;
      case StoreStatus.temporarilyClosed:
        return Colors.orange;
    }
  }

  /// Can users browse & place orders?
  bool get acceptsOrders {
    return const {
      StoreStatus.open,
      StoreStatus.busy,
    }.contains(this);
  }

  Set<StoreStatus> get allowedNextStatuses {
    switch (this) {
      case StoreStatus.open:
        return const {
          StoreStatus.closed,
          StoreStatus.busy,
          StoreStatus.temporarilyClosed,
          StoreStatus.offline,
        };
      case StoreStatus.closed:
        return const {
          StoreStatus.open,
          StoreStatus.offline,
        };
      case StoreStatus.busy:
        return const {
          StoreStatus.open,
          StoreStatus.closed,
          StoreStatus.temporarilyClosed,
          StoreStatus.offline,
        };
      case StoreStatus.temporarilyClosed:
        return const {
          StoreStatus.open,
          StoreStatus.closed,
          StoreStatus.offline,
        };
      case StoreStatus.offline:
        return const {StoreStatus.open, StoreStatus.closed};
    }
  }

  static StoreStatus fromDatabaseValue(String? value,
      {StoreStatus fallback = StoreStatus.closed}) {
    if (value == null || value.isEmpty) return fallback;
    final v = value.trim().toLowerCase().replaceAll('-', '_');
    switch (v) {
      case 'open':
      case 'active':
      case 'available':
      case 'online':
        return StoreStatus.open;
      case 'busy':
      case 'swamped':
      case 'high_traffic':
        return StoreStatus.busy;
      case 'temporarily_closed':
      case 'temp_closed':
      case 'temporarilyclosed':
        return StoreStatus.temporarilyClosed;
      case 'closed':
        return StoreStatus.closed;
      case 'offline':
      case 'inactive':
      case 'disabled':
        return StoreStatus.offline;
      default:
        return fallback;
    }
  }
}

// ============================================================================
// 5. REFUND LIFECYCLE — VISIBLE TO USER / STORE / ADMIN
// ============================================================================
enum RefundStatus {
  /// No refund requested.
  notRequested,

  /// Customer requested a refund.
  requested,

  /// Store / admin is investigating.
  underReview,

  /// Refund approved, payment provider processing it.
  approved,

  /// Refund rejected with reason.
  rejected,

  /// Money returned to customer successfully.
  completed;

  String get databaseValue => name;

  String get displayName {
    switch (this) {
      case RefundStatus.notRequested:
        return 'Not Requested';
      case RefundStatus.requested:
        return 'Requested';
      case RefundStatus.underReview:
        return 'Under Review';
      case RefundStatus.approved:
        return 'Approved';
      case RefundStatus.rejected:
        return 'Rejected';
      case RefundStatus.completed:
        return 'Completed';
    }
  }

  IconData get icon {
    switch (this) {
      case RefundStatus.notRequested:
        return Icons.block_rounded;
      case RefundStatus.requested:
        return Icons.help_outline_rounded;
      case RefundStatus.underReview:
        return Icons.fact_check_rounded;
      case RefundStatus.approved:
        return Icons.check_circle_outline_rounded;
      case RefundStatus.rejected:
        return Icons.cancel_outlined;
      case RefundStatus.completed:
        return Icons.check_circle_rounded;
    }
  }

  Color get color {
    switch (this) {
      case RefundStatus.notRequested:
        return Colors.grey;
      case RefundStatus.requested:
      case RefundStatus.underReview:
        return Colors.amber;
      case RefundStatus.approved:
        return Colors.lightBlue;
      case RefundStatus.rejected:
        return Colors.red;
      case RefundStatus.completed:
        return Colors.green;
    }
  }

  bool get isTerminal {
    return const {RefundStatus.rejected, RefundStatus.completed}.contains(this);
  }

  Set<RefundStatus> get allowedNextStatuses {
    switch (this) {
      case RefundStatus.notRequested:
        return const {RefundStatus.requested};
      case RefundStatus.requested:
        return const {
          RefundStatus.underReview,
          RefundStatus.approved,
          RefundStatus.rejected,
        };
      case RefundStatus.underReview:
        return const {RefundStatus.approved, RefundStatus.rejected};
      case RefundStatus.approved:
        return const {RefundStatus.completed, RefundStatus.rejected};
      case RefundStatus.rejected:
      case RefundStatus.completed:
        return const {};
    }
  }

  static RefundStatus fromDatabaseValue(String? value,
      {RefundStatus fallback = RefundStatus.notRequested}) {
    if (value == null || value.isEmpty) return fallback;
    final v = value.trim().toLowerCase().replaceAll('-', '_');
    switch (v) {
      case 'not_requested':
      case 'none':
        return RefundStatus.notRequested;
      case 'requested':
      case 'initiated':
      case 'submitted':
        return RefundStatus.requested;
      case 'under_review':
      case 'pending_review':
        return RefundStatus.underReview;
      case 'approved':
      case 'accepted':
        return RefundStatus.approved;
      case 'rejected':
      case 'denied':
      case 'declined':
        return RefundStatus.rejected;
      case 'completed':
      case 'done':
      case 'finished':
      case 'paid':
        return RefundStatus.completed;
      default:
        return fallback;
    }
  }
}

// ============================================================================
// 6. ORDER ACCEPTANCE (STORE APP)
// ============================================================================
enum OrderAcceptanceStatus {
  /// Store hasn't responded yet (driver: awaiting response).
  pending,

  /// Store accepted order.
  accepted,

  /// Store declined order.
  declined,

  /// Store auto-accepts orders (store app mode).
  automatic,

  /// Store manually reviews each order (store app mode).
  manual,

  /// Store has disabled order acceptance (store app mode).
  disabled,

  /// Driver notification was not sent yet (driver app).
  notSent,

  /// Driver is waiting for the store to respond (driver app).
  awaitingResponse,

  /// Store rejected the request (driver app).
  rejected,

  /// Request timed out (driver app).
  timedOut;

  String get databaseValue {
    switch (this) {
      case OrderAcceptanceStatus.pending:
        return 'pending';
      case OrderAcceptanceStatus.accepted:
        return 'accepted';
      case OrderAcceptanceStatus.declined:
        return 'declined';
      case OrderAcceptanceStatus.automatic:
        return 'automatic';
      case OrderAcceptanceStatus.manual:
        return 'manual';
      case OrderAcceptanceStatus.disabled:
        return 'disabled';
      case OrderAcceptanceStatus.notSent:
        return 'not_sent';
      case OrderAcceptanceStatus.awaitingResponse:
        return 'awaiting_response';
      case OrderAcceptanceStatus.rejected:
        return 'rejected';
      case OrderAcceptanceStatus.timedOut:
        return 'timed_out';
    }
  }

  /// Human-readable label (UI hints, like the other status enums).
  String get displayName {
    switch (this) {
      case OrderAcceptanceStatus.pending:
        return 'Pending';
      case OrderAcceptanceStatus.accepted:
        return 'Accepted';
      case OrderAcceptanceStatus.declined:
        return 'Declined';
      case OrderAcceptanceStatus.automatic:
        return 'Automatic';
      case OrderAcceptanceStatus.manual:
        return 'Manual';
      case OrderAcceptanceStatus.disabled:
        return 'Disabled';
      case OrderAcceptanceStatus.notSent:
        return 'Not Sent';
      case OrderAcceptanceStatus.awaitingResponse:
        return 'Awaiting Response';
      case OrderAcceptanceStatus.rejected:
        return 'Rejected';
      case OrderAcceptanceStatus.timedOut:
        return 'Timed Out';
    }
  }

  IconData get icon {
    switch (this) {
      case OrderAcceptanceStatus.pending:
      case OrderAcceptanceStatus.awaitingResponse:
        return Icons.hourglass_top_rounded;
      case OrderAcceptanceStatus.accepted:
      case OrderAcceptanceStatus.automatic:
        return Icons.check_circle_rounded;
      case OrderAcceptanceStatus.declined:
      case OrderAcceptanceStatus.rejected:
        return Icons.cancel_rounded;
      case OrderAcceptanceStatus.manual:
        return Icons.touch_app_rounded;
      case OrderAcceptanceStatus.disabled:
        return Icons.not_interested_rounded;
      case OrderAcceptanceStatus.notSent:
        return Icons.send_rounded;
      case OrderAcceptanceStatus.timedOut:
        return Icons.timer_off_rounded;
    }
  }

  Color get color {
    switch (this) {
      case OrderAcceptanceStatus.pending:
      case OrderAcceptanceStatus.awaitingResponse:
        return Colors.amber;
      case OrderAcceptanceStatus.accepted:
      case OrderAcceptanceStatus.automatic:
        return Colors.green;
      case OrderAcceptanceStatus.declined:
      case OrderAcceptanceStatus.rejected:
        return Colors.red;
      case OrderAcceptanceStatus.manual:
        return Colors.blue;
      case OrderAcceptanceStatus.disabled:
        return Colors.grey;
      case OrderAcceptanceStatus.notSent:
        return Colors.blueGrey;
      case OrderAcceptanceStatus.timedOut:
        return Colors.orange;
    }
  }

  static OrderAcceptanceStatus fromDatabaseValue(String? value,
      {OrderAcceptanceStatus fallback = OrderAcceptanceStatus.pending}) {
    if (value == null || value.isEmpty) return fallback;
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    return OrderAcceptanceStatus.values.firstWhere(
      (e) =>
          e.name.toLowerCase() == normalized || e.databaseValue == normalized,
      orElse: () {
        switch (normalized) {
          case 'auto':
          case 'auto_accept':
            return OrderAcceptanceStatus.automatic;
          case 'manual_accept':
            return OrderAcceptanceStatus.manual;
          case 'off':
          case 'paused':
            return OrderAcceptanceStatus.disabled;
          case 'awaiting':
            return OrderAcceptanceStatus.awaitingResponse;
          default:
            return fallback;
        }
      },
    );
  }
}

// ============================================================================
// 7. UTILITIES: VALIDATION
// ============================================================================

/// Checks whether a state transition is allowed. Use this BEFORE writing to
/// the database to enforce consistency across User/Driver/Store apps.
bool isValidStatusTransition<T extends Enum>(T from, T to) {
  Set<Enum> allowed;
  switch (from) {
    case OrderStatus f:
      allowed = f.allowedNextStatuses;
      break;
    case PaymentStatus f:
      allowed = f.allowedNextStatuses;
      break;
    case DriverStatus f:
      allowed = f.allowedNextStatuses;
      break;
    case StoreStatus f:
      allowed = f.allowedNextStatuses;
      break;
    case RefundStatus f:
      allowed = f.allowedNextStatuses;
      break;
    default:
      return true;
  }
  return allowed.contains(to);
}

// ============================================================================
// 8. BACKWARD-COMPAT EXTENSION ALIASES
//
// Historical call sites:
//  - Driver app: OrderStatusX.fromDatabaseValue, PaymentStatusX.fromDatabaseValue,
//    DriverStatusX.fromDatabaseValue
//  - Store app:  OrderStatusExt.fromDatabaseValue, PaymentStatusExt.fromDatabaseValue
// These aliases delegate to the canonical statics above so no app code needs
// to change. (Instance getters like `databaseValue` / `displayName` are now
// declared directly on the enums, so dot-access works everywhere.)
// ============================================================================
extension OrderStatusX on OrderStatus {
  static OrderStatus fromDatabaseValue(String? value,
          {OrderStatus fallback = OrderStatus.pending}) =>
      OrderStatus.fromDatabaseValue(value, fallback: fallback);
}

extension OrderStatusExt on OrderStatus {
  static OrderStatus fromDatabaseValue(String? value,
          {OrderStatus fallback = OrderStatus.pending}) =>
      OrderStatus.fromDatabaseValue(value, fallback: fallback);
}

extension PaymentStatusX on PaymentStatus {
  static PaymentStatus fromDatabaseValue(String? value,
          {PaymentStatus fallback = PaymentStatus.pending}) =>
      PaymentStatus.fromDatabaseValue(value, fallback: fallback);
}

extension PaymentStatusExt on PaymentStatus {
  static PaymentStatus fromDatabaseValue(String? value,
          {PaymentStatus fallback = PaymentStatus.pending}) =>
      PaymentStatus.fromDatabaseValue(value, fallback: fallback);
}

extension DriverStatusX on DriverStatus {
  static DriverStatus fromDatabaseValue(String? value,
          {DriverStatus fallback = DriverStatus.offline}) =>
      DriverStatus.fromDatabaseValue(value, fallback: fallback);
}

extension DriverStatusExt on DriverStatus {
  static DriverStatus fromDatabaseValue(String? value,
          {DriverStatus fallback = DriverStatus.offline}) =>
      DriverStatus.fromDatabaseValue(value, fallback: fallback);
}

extension StoreStatusX on StoreStatus {
  static StoreStatus fromDatabaseValue(String? value,
          {StoreStatus fallback = StoreStatus.closed}) =>
      StoreStatus.fromDatabaseValue(value, fallback: fallback);
}

extension StoreStatusExt on StoreStatus {
  static StoreStatus fromDatabaseValue(String? value,
          {StoreStatus fallback = StoreStatus.closed}) =>
      StoreStatus.fromDatabaseValue(value, fallback: fallback);
}

extension RefundStatusX on RefundStatus {
  static RefundStatus fromDatabaseValue(String? value,
          {RefundStatus fallback = RefundStatus.notRequested}) =>
      RefundStatus.fromDatabaseValue(value, fallback: fallback);
}

extension RefundStatusExt on RefundStatus {
  static RefundStatus fromDatabaseValue(String? value,
          {RefundStatus fallback = RefundStatus.notRequested}) =>
      RefundStatus.fromDatabaseValue(value, fallback: fallback);
}

extension OrderAcceptanceStatusX on OrderAcceptanceStatus {
  static OrderAcceptanceStatus fromDatabaseValue(String? value,
          {OrderAcceptanceStatus fallback = OrderAcceptanceStatus.pending}) =>
      OrderAcceptanceStatus.fromDatabaseValue(value, fallback: fallback);
}

extension OrderAcceptanceStatusExt on OrderAcceptanceStatus {
  static OrderAcceptanceStatus fromDatabaseValue(String? value,
          {OrderAcceptanceStatus fallback = OrderAcceptanceStatus.pending}) =>
      OrderAcceptanceStatus.fromDatabaseValue(value, fallback: fallback);
}
