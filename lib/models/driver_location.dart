/// A driver's last known position, as published by the driver app's
/// location services into the shared `driver_locations` table (and mirrored
/// onto each `driver_assignments` row for per-order reads).
///
/// Every consumer — customer, store, admin — uses this one model so
/// "is this driver still live?" is decided in exactly one place instead of
/// being re-derived (and drifting) across four apps.
class DriverLocation {
  final String driverId;

  /// Last known coordinates, in WGS84 decimal degrees. Null until the
  /// driver app publishes its first fix for the day.
  final double? latitude;
  final double? longitude;

  /// When this fix was captured by the driver's GPS (not when it reached
  /// the DB — the driver app writes this value directly).
  final DateTime? lastUpdate;

  /// Horizontal accuracy in meters (null when the platform didn't report).
  final double? accuracy;

  /// Ground speed in meters/second (null when stationary/not reported).
  final double? speed;

  /// Course over ground in degrees, 0–360 (null when not reported).
  final double? heading;

  const DriverLocation({
    required this.driverId,
    this.latitude,
    this.longitude,
    this.lastUpdate,
    this.accuracy,
    this.speed,
    this.heading,
  });

  bool get hasPosition => latitude != null && longitude != null;

  /// Whether this fix is recent enough to render as "live".
  ///
  /// The driver app publishes at most once every 3 seconds, so a fix
  /// younger than [maxAge] (default 30 s) is treated as live; older fixes
  /// mean the driver's app is backgrounded, offline, or the foreground
  /// service stopped (e.g. order delivered). Consumers should show a
  /// stale/offline state rather than a moving marker when this is false.
  bool isFresh({Duration maxAge = const Duration(seconds: 30)}) {
    final update = lastUpdate;
    if (update == null) return false;
    return DateTime.now().difference(update) <= maxAge;
  }

  factory DriverLocation.fromJson(Map<String, dynamic> json) {
    return DriverLocation(
      driverId: json['driver_id']?.toString() ?? '',
      latitude: _asDouble(json['current_lat']),
      longitude: _asDouble(json['current_lng']),
      lastUpdate: _asDateTime(json['last_location_update']),
      accuracy: _asDouble(json['location_accuracy']),
      speed: _asDouble(json['location_speed']),
      heading: _asDouble(json['location_heading']),
    );
  }

  Map<String, dynamic> toJson() => {
        'driver_id': driverId,
        if (latitude != null) 'current_lat': latitude,
        if (longitude != null) 'current_lng': longitude,
        if (lastUpdate != null)
          'last_location_update': lastUpdate!.toIso8601String(),
        if (accuracy != null) 'location_accuracy': accuracy,
        if (speed != null) 'location_speed': speed,
        if (heading != null) 'location_heading': heading,
      };

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  DriverLocation copyWith({
    double? latitude,
    double? longitude,
    DateTime? lastUpdate,
    double? accuracy,
    double? speed,
    double? heading,
    bool clearPosition = false,
  }) {
    return DriverLocation(
      driverId: driverId,
      latitude: clearPosition ? null : (latitude ?? this.latitude),
      longitude: clearPosition ? null : (longitude ?? this.longitude),
      lastUpdate: clearPosition ? null : (lastUpdate ?? this.lastUpdate),
      accuracy: clearPosition ? null : (accuracy ?? this.accuracy),
      speed: clearPosition ? null : (speed ?? this.speed),
      heading: clearPosition ? null : (heading ?? this.heading),
    );
  }
}
