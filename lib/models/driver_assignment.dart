class DriverModel {
  final String id;
  final String userId;
  final String fullName;
  final String contactNumber;
  final String? imageUrl;
  final String? vehicleMake;
  final String? vehicleModel;
  final String? vehicleColor;
  final String? vehiclePlate;
  final double? rating;
  final String? vehicleType;
  final bool isVerified;

  DriverModel({
    required this.id,
    required this.userId,
    required this.fullName,
    required this.contactNumber,
    this.imageUrl,
    this.vehicleMake,
    this.vehicleModel,
    this.vehicleColor,
    this.vehiclePlate,
    this.rating,
    this.vehicleType,
    required this.isVerified,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'full_name': fullName,
        'contact_number': contactNumber,
        'image_url': imageUrl,
        'vehicle_make': vehicleMake,
        'vehicle_model': vehicleModel,
        'vehicle_color': vehicleColor,
        'vehicle_plate': vehiclePlate,
        'rating': rating,
        'vehicle_type': vehicleType,
        'is_verified': isVerified,
      };

  factory DriverModel.fromJson(Map<String, dynamic> json) => DriverModel(
        id: json['id'] as String? ?? '',
        userId: json['user_id'] as String? ?? '',
        fullName: json['full_name'] as String? ?? 'Assigned Driver',
        contactNumber: json['contact_number'] as String? ?? '',
        imageUrl: json['image_url'] as String?,
        vehicleMake: json['vehicle_make'] as String?,
        vehicleModel: json['vehicle_model'] as String?,
        vehicleColor: json['vehicle_color'] as String?,
        vehiclePlate: json['vehicle_plate'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        vehicleType: json['vehicle_type'] as String?,
        isVerified: json['is_verified'] as bool? ?? false,
      );

  String get vehicleDisplay {
    final parts = <String>[
      if (vehicleColor != null && vehicleColor!.isNotEmpty) vehicleColor!,
      if (vehicleMake != null && vehicleMake!.isNotEmpty) vehicleMake!,
      if (vehicleModel != null && vehicleModel!.isNotEmpty) vehicleModel!,
    ];
    return parts.join(' ');
  }
}

/// Dispatch-offer status vocabulary written to `driver_assignments.status`.
///
/// The remote column is unconstrained text, so these values are pinned here and
/// by the dispatch functions in
/// `lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql` rather than by
/// a database constraint. See docs/phase_b_contract.md.
abstract final class DriverAssignmentStatus {
  /// A driver has a live, unanswered offer that is counting down.
  static const String offered = 'offered';

  /// The sweep cleared an unanswered offer; the order went back to the queue.
  static const String expired = 'expired';

  /// The driver turned the offer down; the order went back to the queue.
  /// Written by the `decline_dispatch_offer` RPC.
  static const String declined = 'declined';

  /// A driver holds the assignment.
  static const String assigned = 'assigned';
}

class DriverAssignmentModel {
  final String id;
  final String orderId;
  final String driverId;
  final String status;
  final String? notes;
  final double? currentLat;
  final double? currentLng;
  final DateTime? lastLocationUpdate;
  final double? locationAccuracy;
  final double? locationSpeed;
  final double? locationHeading;
  final DateTime? acceptedAt;
  final DateTime? pickedUpAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DriverModel? driver;

  /// Phase B — dispatch offer timeout.
  ///
  /// When the assignment represents a pending dispatch offer, these fields
  /// describe the time-boxed offer:
  ///
  /// - [offerExpiresAt]: absolute expiry of the offer
  ///   (creation time + [timeoutSeconds]).
  /// - [timeoutSeconds]: the configured timeout that produced [offerExpiresAt].
  ///
  /// Both are nullable so assignments that never went through a dispatch offer
  /// continue to parse unchanged.
  final DateTime? offerExpiresAt;
  final int? timeoutSeconds;

  DriverAssignmentModel({
    required this.id,
    required this.orderId,
    required this.driverId,
    required this.status,
    this.notes,
    this.currentLat,
    this.currentLng,
    this.lastLocationUpdate,
    this.locationAccuracy,
    this.locationSpeed,
    this.locationHeading,
    this.acceptedAt,
    this.pickedUpAt,
    this.deliveredAt,
    this.cancelledAt,
    required this.createdAt,
    required this.updatedAt,
    this.driver,
    this.offerExpiresAt,
    this.timeoutSeconds,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'order_id': orderId,
        'driver_id': driverId,
        'status': status,
        'notes': notes,
        'current_lat': currentLat,
        'current_lng': currentLng,
        'last_location_update': lastLocationUpdate?.toIso8601String(),
        'location_accuracy': locationAccuracy,
        'location_speed': locationSpeed,
        'location_heading': locationHeading,
        'accepted_at': acceptedAt?.toIso8601String(),
        'picked_up_at': pickedUpAt?.toIso8601String(),
        'delivered_at': deliveredAt?.toIso8601String(),
        'cancelled_at': cancelledAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        if (driver != null) 'drivers': driver!.toJson(),
        // Phase B — dispatch offer timeout.
        if (offerExpiresAt != null)
          'offer_expires_at': offerExpiresAt!.toIso8601String(),
        if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
      };

  factory DriverAssignmentModel.fromJson(Map<String, dynamic> json) {
    final driverData = json['drivers'] as Map<String, dynamic>?;

    return DriverAssignmentModel(
      id: json['id'] as String? ?? '',
      orderId: json['order_id'] as String? ?? '',
      driverId: json['driver_id'] as String? ?? '',
      status: json['status'] as String? ?? 'assigned',
      notes: json['notes'] as String?,
      currentLat: _asDouble(json['current_lat']),
      currentLng: _asDouble(json['current_lng']),
      lastLocationUpdate: _asDateTime(json['last_location_update']),
      locationAccuracy: _asDouble(json['location_accuracy']),
      locationSpeed: _asDouble(json['location_speed']),
      locationHeading: _asDouble(json['location_heading']),
      acceptedAt: _asDateTime(json['accepted_at']),
      pickedUpAt: _asDateTime(json['picked_up_at']),
      deliveredAt: _asDateTime(json['delivered_at']),
      cancelledAt: _asDateTime(json['cancelled_at']),
      createdAt: _asDateTime(json['created_at']) ?? DateTime.now(),
      updatedAt: _asDateTime(json['updated_at']) ?? DateTime.now(),
      driver: driverData != null ? DriverModel.fromJson(driverData) : null,
      // Phase B — dispatch offer timeout.
      offerExpiresAt: _asDateTime(json['offer_expires_at']),
      timeoutSeconds: json['timeout_seconds'] == null
          ? null
          : (json['timeout_seconds'] as num).toInt(),
    );
  }

  bool get hasLiveLocation => currentLat != null && currentLng != null;

  /// Value of [status] while a driver holds a live, unanswered dispatch offer.
  bool get isOfferedStatus =>
      status.toLowerCase() == DriverAssignmentStatus.offered;

  /// Value of [status] once the expiry sweep cleared an unanswered offer.
  bool get isExpiredOfferStatus =>
      status.toLowerCase() == DriverAssignmentStatus.expired;

  /// Value of [status] once the driver declined the offer.
  bool get isDeclinedOfferStatus =>
      status.toLowerCase() == DriverAssignmentStatus.declined;

  /// Whether the offer is over in either way (expired or declined), so the
  /// driver app should stop showing the countdown and offer buttons.
  bool get isClosedOfferStatus => isExpiredOfferStatus || isDeclinedOfferStatus;

  /// Whether this assignment is a live dispatch offer the driver can still
  /// answer.
  ///
  /// An offer is only live while the server marks it [isOfferedStatus] and has
  /// stamped an [offerExpiresAt]. The dispatch-offer vocabulary is pinned by
  /// docs/phase_b_contract.md and the enforce-dispatch-offer-timeout function.
  bool get isPendingOffer => isOfferedStatus && offerExpiresAt != null;

  /// Time left on the offer, or null when there is no offer expiry.
  /// Negative once the offer is past due, so callers can show "expired".
  Duration? offerRemainingAt(DateTime now) {
    final expiresAt = offerExpiresAt;
    if (expiresAt == null) return null;
    return expiresAt.difference(now);
  }

  /// Time left on the offer measured against the local clock.
  Duration? get offerRemaining => offerRemainingAt(DateTime.now());

  /// Whether the offer's expiry has passed, measured against [now].
  bool isOfferExpiredAt(DateTime now) {
    final expiresAt = offerExpiresAt;
    if (expiresAt == null) return false;
    return !now.isBefore(expiresAt);
  }

  /// Whether the offer's expiry has passed.
  bool get isOfferExpired => isOfferExpiredAt(DateTime.now());

  /// Whether the driver can still accept or decline, measured against [now].
  bool canRespondToOfferAt(DateTime now) =>
      isPendingOffer && !isOfferExpiredAt(now);

  /// Whether the driver can still accept or decline this assignment.
  ///
  /// Drives the accept/decline buttons: a live offer that has not timed out.
  bool get canRespondToOffer => canRespondToOfferAt(DateTime.now());

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return DateTime.tryParse(value.toString());
  }
}
