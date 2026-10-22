/// A single in-app notification, persisted in the `notifications` table so
/// users can read order updates they missed while offline.
///
/// Shared by the Customer, Driver, and Store apps. Each app used to carry its
/// own copy that differed only in the doc comment — this is now the canonical
/// version.
class UserNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final String? orderId;
  final String? orderNumber;
  final String? status;
  final Map<String, dynamic> data;
  final bool isRead;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UserNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.orderId,
    this.orderNumber,
    this.status,
    this.data = const {},
    this.isRead = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserNotification.fromJson(Map<String, dynamic> json) {
    return UserNotification(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? 'order',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      orderId: json['order_id']?.toString(),
      orderNumber: json['order_number']?.toString(),
      status: json['status']?.toString(),
      data: (json['data'] is Map<String, dynamic>)
          ? (json['data'] as Map<String, dynamic>)
          : const {},
      isRead: json['is_read'] == true,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'body': body,
        'order_id': orderId,
        'order_number': orderNumber,
        'status': status,
        'data': data,
        'is_read': isRead,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  UserNotification copyWith({bool? isRead}) => UserNotification(
        id: id,
        type: type,
        title: title,
        body: body,
        orderId: orderId,
        orderNumber: orderNumber,
        status: status,
        data: data,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserNotification &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          isRead == other.isRead;

  @override
  int get hashCode => Object.hash(id, isRead);

  /// Optional deep-link destination, if the notification is order-related.
  bool get isOrderRelated => orderId != null && orderId!.isNotEmpty;
}
