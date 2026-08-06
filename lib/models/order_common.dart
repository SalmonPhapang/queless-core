// ============================================================================
// QUELESS CORE — SHARED ORDER SUB-MODELS
//
// These small value types are byte-for-byte the same in the customer and store
// apps (they live in each app's lib/models/order.dart). They are lifted here
// so the two apps can never drift apart again.
// ============================================================================

class SelectedOption {
  final String groupName;
  final String optionName;
  final double priceAdjustment;

  SelectedOption({
    required this.groupName,
    required this.optionName,
    required this.priceAdjustment,
  });

  Map<String, dynamic> toJson() => {
        'group_name': groupName,
        'option_name': optionName,
        'price_adjustment': priceAdjustment,
      };

  factory SelectedOption.fromJson(Map<String, dynamic> json) => SelectedOption(
        groupName: json['group_name'] as String? ?? '',
        optionName: json['option_name'] as String? ?? '',
        priceAdjustment: (json['price_adjustment'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectedOption &&
          runtimeType == other.runtimeType &&
          groupName == other.groupName &&
          optionName == other.optionName &&
          priceAdjustment == other.priceAdjustment;

  @override
  int get hashCode =>
      groupName.hashCode ^ optionName.hashCode ^ priceAdjustment.hashCode;
}

class TrackingUpdate {
  final String status;
  final String message;
  final DateTime timestamp;

  TrackingUpdate({
    required this.status,
    required this.message,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'status': status,
        'message': message,
        'timestamp': timestamp.toIso8601String(),
      };

  factory TrackingUpdate.fromJson(Map<String, dynamic> json) => TrackingUpdate(
        status: json['status'] as String? ?? 'pending',
        message: json['message'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'] as String)
            : DateTime.now(),
      );
}

class DriverInfo {
  final String name;
  final String phone;
  final Map<String, dynamic>? location;

  DriverInfo({
    required this.name,
    required this.phone,
    this.location,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'phone': phone,
        'location': location,
      };

  factory DriverInfo.fromJson(Map<String, dynamic> json) => DriverInfo(
        name: json['name'] as String? ?? 'Unknown Driver',
        phone: json['phone'] as String? ?? '',
        location: json['location'] as Map<String, dynamic>?,
      );
}
