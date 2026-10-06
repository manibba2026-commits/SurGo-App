import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';

void main() {
  group('Money', () {
    test('formats centavos as pesos with two decimals', () {
      expect(Money.format(0), '₱0.00');
      expect(Money.format(65), '₱0.65');
      expect(Money.format(18050), '₱180.50');
      expect(Money.format(312000), '₱3,120.00');
    });

    test('formats can omit the symbol for prefixed inputs', () {
      expect(Money.format(18050, symbol: false), '180.50');
    });

    test('groups thousands and keeps negatives outside the symbol', () {
      expect(Money.format(-500), '-₱5.00');
      expect(Money.signed(500), '+₱5.00');
      expect(Money.signed(-500), '-₱5.00');
    });

    test('converts between pesos and centavos', () {
      expect(Money.pesos(180), 18000);
      expect(Money.toPesos(18050), 180.5);
    });

    test('parses typed peso amounts into centavos', () {
      expect(Money.tryParsePesos('500'), 50000);
      expect(Money.tryParsePesos('1,250.50'), 125050);
      expect(Money.tryParsePesos('₱250'), 25000);
      expect(Money.tryParsePesos('12.5'), 1250);
    });

    test('rejects input that is not a usable amount', () {
      expect(Money.tryParsePesos(''), isNull);
      expect(Money.tryParsePesos('abc'), isNull);
      expect(Money.tryParsePesos('1.2.3'), isNull);
      expect(Money.tryParsePesos('12.345'), isNull);
      expect(Money.tryParsePesos('0'), isNull);
    });

    test('round-trips format through parse', () {
      for (final centavos in [1, 99, 100, 6500, 18050, 123456]) {
        final pesos = Money.format(centavos, symbol: false).replaceAll(',', '');
        expect(Money.tryParsePesos(pesos), centavos,
            reason: '₱$pesos should parse back to $centavos');
      }
    });
  });

  group('commission rates', () {
    test('come from config defaults before DbService loads', () {
      expect(FeeCalculator.commissionBpsFor(ServiceType.ride), 1000);
      expect(FeeCalculator.commissionBpsFor(ServiceType.pasuyo), 1500);
      expect(FeeCalculator.commissionBpsFor(ServiceType.rental), 1000);
      expect(FeeCalculator.commissionPercentFor(ServiceType.pasuyo), 15);
    });

    test('configure ignores missing or non-positive values', () {
      addTearDown(() => FeeRates.configure(ride: 1000, pasuyo: 1500, rental: 1000));
      FeeRates.configure(ride: 2000, pasuyo: 0, rental: -1);
      expect(FeeCalculator.commissionBpsFor(ServiceType.ride), 2000);
      expect(FeeCalculator.commissionBpsFor(ServiceType.pasuyo), 1500,
          reason: 'zero must fall back to the default, not disable the fee');
      expect(FeeCalculator.commissionBpsFor(ServiceType.rental), 1000);
    });
  });

  group('FeeCalculator', () {
    test('splits a ride 10% and the halves re-add to the gross', () {
      final b = FeeCalculator.breakdownFor(ServiceType.ride, 6500);
      expect(b.customerPays, 6500);
      expect(b.surgoKeeps, 650);
      expect(b.providerGets, 5850);
      expect(b.providerGets + b.surgoKeeps, b.customerPays);
    });

    test('splits a Pasuyo errand 15%', () {
      final b = FeeCalculator.breakdownFor(ServiceType.pasuyo, 20000);
      expect(b.surgoKeeps, 3000);
      expect(b.providerGets, 17000);
      expect(b.providerGets + b.surgoKeeps, b.customerPays);
    });

    test('the split is exact for every peso amount', () {
      for (var pesos = 1; pesos <= 500; pesos++) {
        final gross = Money.pesos(pesos);
        final b = FeeCalculator.breakdownFor(ServiceType.pasuyo, gross);
        expect(b.providerGets + b.surgoKeeps, gross,
            reason: 'split lost or gained centavos at ₱$pesos');
        expect(b.providerGets, greaterThanOrEqualTo(0));
      }
    });

    test('returns zeroes rather than negative payouts for empty amounts', () {
      for (final service in ServiceType.values) {
        for (final gross in [0, -1, -100000]) {
          final b = FeeCalculator.breakdownFor(service, gross);
          expect(b.customerPays, 0);
          expect(b.providerGets, 0);
          expect(b.surgoKeeps, 0);
        }
      }
    });

    test('labels render through Money so scales cannot drift', () {
      final b = FeeCalculator.breakdownFor(ServiceType.ride, 6500);
      expect(b.customerPaysLabel, Money.format(6500));
      expect(b.providerGetsLabel, Money.format(5850));
    });
  });
}