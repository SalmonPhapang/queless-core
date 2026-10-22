// ============================================================================
// QUELESS CORE — DRIVER DEVICE BINDING CLIENT
//
// One driver account, one phone. This is the app-side half of the
// `driver-device-verify` edge function (see
// supabase/functions/driver-device-verify/index.ts and
// lib/supabase/migrations/20261016_000001_driver_device_binding.sql): it asks
// the server whether the phone the app is running on is still the account's
// active device, and drives the SMS challenge when it is not.
//
//   final binding = DeviceBindingClient(edge: SupabaseConfig.edge, ...);
//   final result   = await binding.check();
//   if (result.status == DeviceBindingStatus.unverified) {
//     await binding.sendVerificationCode();      // auto-sent on the OTP screen
//     final done = await binding.verifyCode('123456');
//   }
//   if (result.shouldSignOut) { ... }
//
// The device id is a UUID the app mints once and stores locally — never an OS
// identifier. Android no longer exposes one to apps (device_info_plus dropped
// ANDROID_ID in 4.0.0 for Google Play policy reasons), and a UUID behaves the
// same on Huawei (HMS) devices, where no Google id exists at all. A reinstall
// is deliberately a new device: it must re-verify by SMS.
//
// The phone number is resolved server-side from users.phone, falling back to
// drivers.contact_number, so it never travels in the request.
// ============================================================================

import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../edge/edge_client.dart';

/// The name of the edge function this client talks to.
const String kDeviceBindingFunction = 'driver-device-verify';

/// What the server says about this phone.
enum DeviceBindingStatus {
  /// This device is the account's active one; nothing more to do.
  verified,

  /// This phone is not recognised; its holder must pass the SMS challenge
  /// before it may become active (an unverified device never gets a row that
  /// carries [DeviceBindingResult.isCurrent]).
  unverified,

  /// Another phone took over this account. The app must sign out.
  superseded,

  /// The code was wrong or expired. Not a reason to sign out — the driver
  /// stays on the verification screen and can try again or resend.
  invalidCode,

  /// The account has no phone number, so no SMS can be sent: the driver has
  /// to contact support. Treated like [superseded] — the app signs out.
  noPhone,

  /// The server could not be reached or answered unexpectedly. Never sign out
  /// on this: a flaky network must not log a driver off mid-shift.
  failed,
}

class DeviceBindingResult {
  const DeviceBindingResult(
    this.status, {
    this.message,
    this.firstVerification = false,
  });

  final DeviceBindingStatus status;

  /// Server-supplied, already translated into a driver-facing sentence.
  final String? message;

  /// True when this result came from passing the SMS challenge.
  final bool firstVerification;

  bool get isVerified => status == DeviceBindingStatus.verified;

  /// Whether the app must end the session: the device is either not current
  /// or not verifiable. [DeviceBindingStatus.failed] deliberately does not
  /// sign anyone out.
  bool get shouldSignOut =>
      status == DeviceBindingStatus.superseded ||
      status == DeviceBindingStatus.unverified ||
      status == DeviceBindingStatus.noPhone;

  @override
  String toString() =>
      'DeviceBindingResult(${status.name}${message == null ? '' : ', $message'})';
}

/// Outcome of asking the server to send an SMS challenge.
class DeviceOtpSendResult {
  const DeviceOtpSendResult({
    required this.sent,
    this.message,
    this.retryAfterSeconds,
  });

  final bool sent;
  final String? message;

  /// Set when the server throttled the request (resend too soon).
  final int? retryAfterSeconds;

  @override
  String toString() =>
      'DeviceOtpSendResult(sent: $sent, retryAfter: $retryAfterSeconds)';
}

/// This install, described by the app. Everything except [id] is best-effort
/// metadata for whoever reads the device list in the database.
class DeviceDescriptor {
  const DeviceDescriptor({
    required this.id,
    this.platform = '',
    this.osVersion = '',
    this.appVersion = '',
  });

  final String id;
  final String platform;
  final String osVersion;
  final String appVersion;

  Map<String, dynamic> toPayload() => <String, dynamic>{
        'device_id': id,
        if (platform.isNotEmpty) 'platform': platform,
        if (osVersion.isNotEmpty) 'os_version': osVersion,
        if (appVersion.isNotEmpty) 'app_version': appVersion,
      };
}

/// A UUID v4, minted once per install.
///
/// `Random.secure()` is used because this value stands in for a device
/// identity; the standard library has no UUID builder and the `uuid` package
/// is not worth a dependency for eight lines.
String newDeviceUuid({Random? random}) {
  final bytes =
      List<int>.generate(16, (_) => (random ?? Random.secure()).nextInt(256));
  // RFC 4122 version 4 and variant bits.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int start, int length) => bytes
      .sublist(start, start + length)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-${hex(8, 2)}-${hex(10, 6)}';
}

class DeviceBindingClient {
  DeviceBindingClient({
    required EdgeClient edge,
    required Future<DeviceDescriptor> Function() descriptor,
  })  : _edge = edge,
        _descriptor = descriptor;

  final EdgeClient _edge;
  final Future<DeviceDescriptor> Function() _descriptor;

  DeviceDescriptor? _resolved;

  /// The device id, resolved once per app run.
  Future<String?> deviceId() async => (await _descriptorId())?.id;

  Future<DeviceDescriptor?> _descriptorId() async {
    if (_resolved != null) return _resolved;
    final descriptor = await _descriptor();
    if (descriptor.id.trim().isEmpty) return null;
    _resolved = descriptor;
    return descriptor;
  }

  /// Is this phone still the account's active device?
  Future<DeviceBindingResult> check() async {
    final descriptor = await _descriptorId();
    if (descriptor == null) {
      return const DeviceBindingResult(DeviceBindingStatus.failed,
          message: 'This device has no identity yet.');
    }

    try {
      final data =
          await _edge.call(kDeviceBindingFunction, body: <String, dynamic>{
        'action': 'check',
        ...descriptor.toPayload(),
      });
      return _parse(data);
    } catch (e) {
      debugPrint('[device] check failed: $e');
      return const DeviceBindingResult(DeviceBindingStatus.failed,
          message: 'We could not check this device. Please try again.');
    }
  }

  /// Sends the SMS challenge to the account's own number (auto-sent by the
  /// verification screen). Returns whether it went out.
  Future<DeviceOtpSendResult> sendVerificationCode() async {
    final descriptor = await _descriptorId();
    if (descriptor == null) {
      return const DeviceOtpSendResult(
          sent: false, message: 'This device has no identity yet.');
    }

    try {
      final data =
          await _edge.call(kDeviceBindingFunction, body: <String, dynamic>{
        'action': 'send_otp',
        ...descriptor.toPayload(),
      });
      return DeviceOtpSendResult(sent: true, message: _messageOf(data));
    } on EdgeFunctionException catch (e) {
      final payload = e.data is Map ? e.data as Map : const <String, dynamic>{};
      return DeviceOtpSendResult(
        sent: false,
        message: e.message,
        retryAfterSeconds: (payload['retry_after_seconds'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('[device] sendVerificationCode failed: $e');
      return const DeviceOtpSendResult(
          sent: false,
          message: 'We could not send the code. Please try again.');
    }
  }

  /// Confirms the code the driver typed and makes this the active device.
  Future<DeviceBindingResult> verifyCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return const DeviceBindingResult(DeviceBindingStatus.failed,
          message: 'Please enter the verification code.');
    }

    final descriptor = await _descriptorId();
    if (descriptor == null) {
      return const DeviceBindingResult(DeviceBindingStatus.failed,
          message: 'This device has no identity yet.');
    }

    try {
      final data =
          await _edge.call(kDeviceBindingFunction, body: <String, dynamic>{
        'action': 'verify_otp',
        'code': trimmed,
        ...descriptor.toPayload(),
      });
      return _parse(data, firstVerification: true);
    } on EdgeFunctionException catch (e) {
      // Wrong or expired code: keep the driver on the verification screen.
      return DeviceBindingResult(DeviceBindingStatus.invalidCode,
          message: e.message);
    } catch (e) {
      debugPrint('[device] verifyCode failed: $e');
      return const DeviceBindingResult(DeviceBindingStatus.failed,
          message: 'We could not verify the code. Please try again.');
    }
  }

  /// Forget the resolved descriptor — used by tests and by a full sign-out.
  void reset() => _resolved = null;

  static DeviceBindingResult _parse(dynamic data,
      {bool firstVerification = false}) {
    if (data is! Map) {
      return DeviceBindingResult(DeviceBindingStatus.failed,
          firstVerification: firstVerification);
    }

    final status = data['status']?.toString().trim().toLowerCase() ?? '';
    return DeviceBindingResult(_statusOf(status),
        message: _messageOf(data), firstVerification: firstVerification);
  }

  static DeviceBindingStatus _statusOf(String status) {
    switch (status) {
      case 'verified':
        return DeviceBindingStatus.verified;
      case 'superseded':
        return DeviceBindingStatus.superseded;
      case 'no_phone':
        return DeviceBindingStatus.noPhone;
      case 'unverified':
        return DeviceBindingStatus.unverified;
      default:
        return DeviceBindingStatus.failed;
    }
  }

  static String? _messageOf(Map data) {
    final message = data['message']?.toString().trim();
    return (message == null || message.isEmpty) ? null : message;
  }
}
