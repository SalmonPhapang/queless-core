import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:queless_core/queless_core.dart';

/// Drives the binding client through a scripted edge function, so the whole
/// protocol (action names, device id, metadata, failure mapping) is pinned
/// without a network or a Supabase project.
class ScriptedEdge {
  final List<(String, Map<String, dynamic>)> calls = [];

  /// Payload the next call returns.
  dynamic reply;

  /// Error the next call throws.
  Object? error;
  int? errorStatus;
  Map<String, dynamic>? errorData;

  Future<dynamic> invoke(
    String functionName,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) async {
    calls.add((functionName, body));
    final failure = error;
    error = null;
    if (failure != null) {
      throw failure is EdgeFunctionException
          ? failure
          : EdgeFunctionException(
              failure.toString(),
              status: errorStatus,
              data: errorData,
            );
    }
    return reply;
  }

  (String, Map<String, dynamic>) get lastCall => calls.last;
}

void main() {
  late ScriptedEdge edge;
  late DeviceBindingClient client;
  late List<DeviceDescriptor> descriptors;

  setUp(() {
    edge = ScriptedEdge();
    descriptors = <DeviceDescriptor>[
      const DeviceDescriptor(
        id: 'device-uuid-0001',
        platform: 'android',
        osVersion: 'Android 14 (SDK 34)',
        appVersion: '1.3.0',
      ),
    ];
    client = DeviceBindingClient(
      edge: EdgeClient(edge.invoke),
      descriptor: () async => descriptors.single,
    );
  });

  test('check asks for this device by id and sends its metadata', () async {
    edge.reply = {'status': 'verified', 'current': true};

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.verified);
    expect(result.isVerified, isTrue);
    expect(result.shouldSignOut, isFalse);

    final (name, body) = edge.lastCall;
    expect(name, kDeviceBindingFunction);
    expect(body['action'], 'check');
    expect(body['device_id'], 'device-uuid-0001');
    expect(body['platform'], 'android');
    expect(body['os_version'], 'Android 14 (SDK 34)');
    expect(body['app_version'], '1.3.0');
    expect(body.containsKey('code'), isFalse);
  });

  test('check maps an unknown device to unverified and says why', () async {
    edge.reply = {'status': 'unverified', 'current': false};

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.unverified);
    expect(result.shouldSignOut, isTrue);
  });

  test('check maps a superseded phone to a sign-out', () async {
    edge.reply = {
      'status': 'superseded',
      'current': false,
      'message': 'This phone is no longer your active device.',
    };

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.superseded);
    expect(result.shouldSignOut, isTrue);
    expect(result.message, contains('no longer'));
  });

  test('check maps a missing phone number to a support message', () async {
    edge.reply = {
      'status': 'no_phone',
      'current': false,
      'message': 'We have no phone number on this account.',
    };

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.noPhone);
    expect(result.shouldSignOut, isTrue);
    expect(result.message, contains('no phone number'));
  });

  test('a network failure never asks the app to sign out', () async {
    edge.error = Exception('connection reset');

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.failed);
    expect(result.shouldSignOut, isFalse);
    expect(result.isVerified, isFalse);
  });

  test('sendVerificationCode sends the challenge for this device', () async {
    edge.reply = {
      'status': 'sent',
      'expires_in_seconds': 600,
      'retry_after_seconds': 60,
    };

    final result = await client.sendVerificationCode();

    expect(result.sent, isTrue);
    expect(edge.lastCall.$2['action'], 'send_otp');
    expect(edge.lastCall.$2['device_id'], 'device-uuid-0001');
  });

  test('a resend throttle is reported with its retry window', () async {
    edge.error = const EdgeFunctionException(
      'Please wait before requesting another verification code.',
      status: 429,
      data: {'error': 'Please wait.', 'retry_after_seconds': 60},
    );

    final result = await client.sendVerificationCode();

    expect(result.sent, isFalse);
    expect(result.retryAfterSeconds, 60);
    expect(result.message, contains('wait'));
  });

  test('verifyCode makes this the active device', () async {
    edge.reply = {
      'status': 'verified',
      'current': true,
      'first_verification': true,
    };

    final result = await client.verifyCode('123456');

    expect(result.status, DeviceBindingStatus.verified);
    expect(result.firstVerification, isTrue);
    expect(edge.lastCall.$2['action'], 'verify_otp');
    expect(edge.lastCall.$2['code'], '123456');
    expect(edge.lastCall.$2['device_id'], 'device-uuid-0001');
  });

  test('a wrong code stays on the verification screen', () async {
    edge.error =
        const EdgeFunctionException('Invalid verification code.', status: 400);

    final result = await client.verifyCode('000000');

    expect(result.status, DeviceBindingStatus.invalidCode);
    // A typo must never sign the driver out.
    expect(result.shouldSignOut, isFalse);
    expect(result.message, contains('Invalid'));
  });

  test('an empty code is rejected before any network call', () async {
    final result = await client.verifyCode('   ');

    expect(result.status, DeviceBindingStatus.failed);
    expect(edge.calls, isEmpty);
  });

  test('a device with no identity reports failed without calling out',
      () async {
    descriptors = <DeviceDescriptor>[const DeviceDescriptor(id: '')];

    final result = await client.check();

    expect(result.status, DeviceBindingStatus.failed);
    expect(edge.calls, isEmpty);
  });

  test('device id is resolved once per run', () async {
    edge.reply = {'status': 'verified'};
    await client.check();
    await client.check();

    expect(edge.calls.length, 2);
    // Same descriptor both times (the app mints it once and stores it).
    expect(
      edge.calls.every(
        (call) => call.$2['device_id'] == 'device-uuid-0001',
      ),
      isTrue,
    );
  });

  test('newDeviceUuid mints RFC 4122 v4 identifiers', () {
    final uuid = newDeviceUuid(random: Random(42));

    expect(
      uuid,
      matches(RegExp(
        '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$',
      )),
    );
    // Deterministic per seed, distinct across seeds (two phones, two ids).
    expect(newDeviceUuid(random: Random(42)), uuid);
    expect(newDeviceUuid(random: Random(7)), isNot(uuid));
    expect(newDeviceUuid(), isNot(uuid));
  });

  test('the same device stays recognised across app runs', () async {
    edge.reply = {'status': 'verified'};

    // A fresh client, as after an app restart, reusing the stored descriptor.
    final restarted = DeviceBindingClient(
      edge: EdgeClient(edge.invoke),
      descriptor: () async => descriptors.single,
    );

    expect((await restarted.check()).status, DeviceBindingStatus.verified);
  });
}
