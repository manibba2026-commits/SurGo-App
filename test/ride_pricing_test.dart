import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart' show MapPoint;
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/services/ride_pricing.dart';

void main() {
  group('ride platform fee', () {
    test('is ₱2 per kilometre inside the ₱5–₱30 band', () {
      expect(RidePricing.platformFee(TripDistance.seeded(3.2)), 640);
      expect(RidePricing.platformFee(TripDistance.seeded(10)), 2000);
      expect(RidePricing.platformFee(TripDistance.seeded(15)), 3000);
    });

    test('charges the ₱5 floor for short trips and unknown distance', () {
      expect(RidePricing.platformFee(TripDistance.seeded(0.5)), 500);
      expect(RidePricing.platformFee(TripDistance.seeded(2.5)), 500);
      expect(RidePricing.platformFee(TripDistance.unknown), 500);
    });

    test('caps at ₱30 for long trips', () {
      expect(RidePricing.platformFee(TripDistance.seeded(15.01)), 3000);
      expect(RidePricing.platformFee(TripDistance.seeded(100)), 3000);
    });

    test('rounds to whole centavos without floating-point currency maths', () {
      // 3.002 km = 3002 m; 3002 * 200 / 1000 = 600.4 -> 600 centavos.
      expect(RidePricing.platformFee(TripDistance.seeded(3.002)), 600);
      // 3.003 km = 3003 m; 600.6 -> 601 centavos (half-up at the centavo).
      expect(RidePricing.platformFee(TripDistance.seeded(3.003)), 601);
    });

    test('rereads the three rules from configuration', () {
      final perKm = RidePricing.perKmFeeCentavos;
      final minimum = RidePricing.minFeeCentavos;
      final maximum = RidePricing.maxFeeCentavos;
      addTearDown(() => RidePricing.configure(
            perKm: perKm,
            minimum: minimum,
            maximum: maximum,
          ));

      RidePricing.configure(perKm: 300, minimum: 1000, maximum: 5000);
      expect(RidePricing.platformFee(TripDistance.seeded(3)), 1000);
      expect(RidePricing.platformFee(TripDistance.seeded(10)), 3000);
      expect(RidePricing.platformFee(TripDistance.seeded(100)), 5000);
    });
  });

  group('ride price split', () {
    test('provider fare and platform fee are separate amounts', () {
      final price = RidePricing.price(
        providerFare: Money.pesos(180),
        distance: TripDistance.seeded(6),
      );

      expect(price.providerFare, 18000);
      expect(price.platformFee, 1200);
      expect(price.customerTotal, 19200);
      expect(price.providerFare + price.platformFee, price.customerTotal);
    });

    test('the breakdown gives the provider the whole fare', () {
      final price = RidePricing.price(
        providerFare: Money.pesos(180),
        distance: TripDistance.seeded(6),
      );
      final breakdown = RidePricing.breakdown(price);

      expect(breakdown.basis, FeeBasis.distancePlatformFee);
      expect(breakdown.providerGets, price.providerFare);
      expect(breakdown.surgoKeeps, price.platformFee);
      expect(breakdown.customerPays, price.customerTotal);
    });

    test('every centavo is accounted for across distances', () {
      for (var metres = 0; metres <= 40000; metres += 250) {
        final price = RidePricing.price(
          providerFare: 5000,
          distance: TripDistance.seeded(metres / 1000),
        );
        expect(price.customerTotal, price.providerFare + price.platformFee);
        expect(price.platformFee,
            inInclusiveRange(RidePricing.minFeeCentavos,
                RidePricing.maxFeeCentavos));
      }
    });
  });

  group('distance source', () {
    test('a seeded distance is labelled as a demo route', () {
      final distance = TripDistance.seeded(4.2);
      expect(distance.kilometres, 4.2);
      expect(distance.source, DistanceSource.seededRoute);
      expect(distance.isMeasured, isTrue);
      expect(distance.label, '4.2 km');
      expect(distance.caveat, 'demo route distance');
    });

    test('a coordinate pair is a straight-line estimate, not a route', () {
      // Roughly 1 km apart at this latitude.
      final distance = TripDistance.between(
        const MapPoint(9.0790, 126.1980),
        const MapPoint(9.0880, 126.1980),
      );
      expect(distance.source, DistanceSource.straightLine);
      expect(distance.label, endsWith('km straight-line'));
      expect(distance.caveat, contains('no road routing'));
    });

    test('a missing coordinate says distance is unavailable', () {
      final distance = TripDistance.between(null, const MapPoint(9.079, 126.198));
      expect(distance.source, DistanceSource.unknown);
      expect(distance.isMeasured, isFalse);
      expect(distance.label, 'distance unavailable');
    });

    test('a request with coordinates is priced on them over its seeded km', () {
      final price = RidePricing.forRequest(
        providerFare: 10000,
        seededKilometres: 99,
        pickup: const MapPoint(9.0790, 126.1980),
        dropoff: const MapPoint(9.0880, 126.1980),
      );
      expect(price.distance.source, DistanceSource.straightLine);
      expect(price.platformFee, lessThan(RidePricing.maxFeeCentavos));
    });

    test('a request without coordinates falls back to its seeded distance', () {
      final price = RidePricing.forRequest(
        providerFare: 10000,
        seededKilometres: 3.2,
      );
      expect(price.distance.source, DistanceSource.seededRoute);
      expect(price.platformFee, 640);
    });
  });
}
