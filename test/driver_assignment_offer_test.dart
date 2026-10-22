// Phase B — dispatch offer plumbing in the shared DriverAssignmentModel.
//
// The vocabulary under test is pinned by docs/phase_b_contract.md and the
// dispatch functions in lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql:
//   status 'offered' + offer_expires_at  -> live, answerable offer
//   status 'expired'                     -> enforce_dispatch_offer_timeout cleared it
//   status 'declined'                    -> decline_dispatch_offer refused it
//   no offer fields                      -> legacy assignment row

import 'package:flutter_test/flutter_test.dart';
import 'package:queless_core/queless_core.dart';

Map<String, dynamic> assignmentJson({
  String status = 'assigned',
  Map<String, dynamic> offer = const {},
  int? timeoutSeconds,
}) =>
    <String, dynamic>{
      'id': 'a1',
      'order_id': 'o1',
      'driver_id': 'd1',
      'status': status,
      'created_at': '2026-10-11T10:00:00.000Z',
      'updated_at': '2026-10-11T10:00:00.000Z',
      ...offer,
      if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
    };

void main() {
  group('legacy rows', () {
    test('parse without offer fields and are never a pending offer', () {
      final model = DriverAssignmentModel.fromJson(assignmentJson());

      expect(model.offerExpiresAt, isNull);
      expect(model.timeoutSeconds, isNull);
      expect(model.isPendingOffer, isFalse);
      expect(model.isOfferExpired, isFalse);
      expect(model.canRespondToOffer, isFalse);
      expect(model.offerRemaining, isNull);
    });

    test('an expiry-less assigned row is not treated as an offer', () {
      final model = DriverAssignmentModel.fromJson(
        assignmentJson(status: 'assigned', timeoutSeconds: 60),
      );

      expect(model.isPendingOffer, isFalse);
      expect(model.canRespondToOffer, isFalse);
    });
  });

  group('round trip', () {
    test('toJson emits offer_expires_at and timeout_seconds', () {
      final model = DriverAssignmentModel.fromJson(
        assignmentJson(
          status: DriverAssignmentStatus.offered,
          offer: {'offer_expires_at': '2026-10-11T10:01:00.000Z'},
          timeoutSeconds: 60,
        ),
      );

      final json = model.toJson();
      expect(json['offer_expires_at'], '2026-10-11T10:01:00.000Z');
      expect(json['timeout_seconds'], 60);
      expect(json['status'], 'offered');
    });

    test('legacy rows omit the offer fields entirely', () {
      final json = DriverAssignmentModel.fromJson(assignmentJson()).toJson();

      expect(json.containsKey('offer_expires_at'), isFalse);
      expect(json.containsKey('timeout_seconds'), isFalse);
    });
  });

  group('live offer', () {
    final expiry = DateTime.parse('2026-10-11T10:01:00.000Z');
    final model = DriverAssignmentModel.fromJson(
      assignmentJson(
        status: DriverAssignmentStatus.offered,
        offer: {'offer_expires_at': '2026-10-11T10:01:00.000Z'},
        timeoutSeconds: 60,
      ),
    );

    test('is a pending offer that can be answered before expiry', () {
      expect(model.isPendingOffer, isTrue);
      expect(model.isOfferedStatus, isTrue);
      expect(model.isExpiredOfferStatus, isFalse);
      expect(model.isDeclinedOfferStatus, isFalse);
      expect(model.isClosedOfferStatus, isFalse);
      expect(model.canRespondToOffer, isTrue);
    });

    test('reports the remaining time against a supplied clock', () {
      expect(
        model.offerRemainingAt(DateTime.parse('2026-10-11T10:00:15.000Z')),
        const Duration(seconds: 45),
      );
    });

    test('stops being answerable at the expiry instant', () {
      expect(model.isOfferExpiredAt(expiry), isTrue);
      expect(
        model.isOfferExpiredAt(expiry.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        model.canRespondToOfferAt(expiry),
        isFalse,
        reason: 'the driver app disables accept/decline after expiry',
      );
    });
  });

  group('cleared offer', () {
    test('an expired row is neither pending nor answerable', () {
      final model = DriverAssignmentModel.fromJson(
        assignmentJson(status: DriverAssignmentStatus.expired),
      );

      expect(model.isExpiredOfferStatus, isTrue);
      expect(model.isDeclinedOfferStatus, isFalse);
      expect(model.isClosedOfferStatus, isTrue);
      expect(model.isPendingOffer, isFalse);
      expect(model.isOfferExpired, isFalse);
      expect(model.canRespondToOffer, isFalse);
    });

    test('a declined row is closed but never counts as expired', () {
      final model = DriverAssignmentModel.fromJson(
        assignmentJson(status: DriverAssignmentStatus.declined),
      );

      expect(model.isDeclinedOfferStatus, isTrue);
      expect(model.isExpiredOfferStatus, isFalse);
      expect(model.isClosedOfferStatus, isTrue);
      expect(model.isPendingOffer, isFalse);
      expect(model.canRespondToOffer, isFalse);
    });
  });
}
