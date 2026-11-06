import 'package:flutter/foundation.dart';

import '../data/db_models.dart';
import '../state/geo.dart';
import 'fee_calculator.dart';
import 'money.dart';

/// Where a trip's kilometre figure came from.
///
/// SurGo has no routing engine in this build, so the app must never present a
/// distance as though it had been driven. The source travels with the number
/// and the screens say what it is.
enum DistanceSource {
  /// The distance that came with the seeded trip record.
  seededRoute,

  /// Straight line between the two coordinates in the mock place table.
  /// A floor-plan answer, not a road answer: it always under-states the trip.
  straightLine,

  /// Neither is available, so only the contractual minimum can be charged.
  unknown,
}

@immutable
class TripDistance {
  const TripDistance({required this.kilometres, required this.source});

  final double kilometres;
  final DistanceSource source;

  bool get isMeasured => source != DistanceSource.unknown;

  /// "8.4 km" plus, for anything that is not a driven route, what kind of
  /// estimate it actually is.
  String get label => switch (source) {
        DistanceSource.seededRoute => '${_km()} km',
        DistanceSource.straightLine => '${_km()} km straight-line',
        DistanceSource.unknown => 'distance unavailable',
      };

  /// The honest caveat a pricing row shows next to the fee.
  String get caveat => switch (source) {
        DistanceSource.seededRoute => 'demo route distance',
        DistanceSource.straightLine =>
          'mock estimate — no road routing in this build',
        DistanceSource.unknown => 'minimum platform fee applied',
      };

  String _km() => kilometres.toStringAsFixed(1);

  /// No distance at all: only the minimum fee can be charged.
  static const TripDistance unknown =
      TripDistance(kilometres: 0, source: DistanceSource.unknown);

  /// Straight line between two mock places; unknown if either is missing.
  factory TripDistance.between(MapPoint? from, MapPoint? to) {
    if (from == null || to == null) return unknown;
    return TripDistance(
      kilometres: haversineKm(from, to),
      source: DistanceSource.straightLine,
    );
  }

  /// A distance that arrived with a seeded record.
  factory TripDistance.seeded(double kilometres) =>
      TripDistance(kilometres: kilometres, source: DistanceSource.seededRoute);
}

/// How a bare kilometre figure carried by a request or history row should be
/// read out.
///
/// `0` is not a short trip, it is the absence of a measurement — the same value
/// the app stores when neither place resolved to a coordinate. Printing it as
/// "0.0 km" would tell a rider the passenger is standing next to them.
String distanceLabelKm(double kilometres) => kilometres <= 0
    ? 'no measured distance'
    : '${kilometres} km';

/// The three amounts a ride actually has.
///
/// [providerFare] is what the rider agreed to earn and keeps in full,
/// [platformFee] is what SurGo charges for using the platform, and
/// [customerTotal] is what changes hands. Keeping them apart is the point: the
/// old model folded the platform's cut into the fare, which made the rider's
/// earnings depend on a percentage the customer never saw.
///
/// All amounts are integer centavos.
@immutable
class RidePrice {
  const RidePrice({
    required this.providerFare,
    required this.platformFee,
    required this.distance,
  });

  final int providerFare;
  final int platformFee;
  final TripDistance distance;

  int get customerTotal => providerFare + platformFee;

  String get providerFareLabel => Money.format(providerFare);
  String get platformFeeLabel => Money.format(platformFee);
  String get customerTotalLabel => Money.format(customerTotal);
}

/// The per-kilometre platform fee for rides, in integer centavos.
///
/// ₱2.00 per km, floored at ₱5.00 and capped at ₱30.00. The distance is turned
/// into whole metres before the multiplication so no peso amount ever passes
/// through a floating-point division: `metres * 2 / 1000` with integer
/// round-half-up is the same arithmetic a receipt would do by hand.
class RidePricing {
  RidePricing._();

  static int perKmFeeCentavos = 200; // ₱2.00 per km
  static int minFeeCentavos = 500; // ₱5.00 floor
  static int maxFeeCentavos = 3000; // ₱30.00 ceiling

  /// Loads the fee rules from the seed, ignoring a value that would price a
  /// ride below its own floor or above the ceiling.
  static void configure({
    required int perKm,
    required int minimum,
    required int maximum,
  }) {
    if (perKm > 0) perKmFeeCentavos = perKm;
    if (minimum > 0) minFeeCentavos = minimum;
    if (maximum >= minFeeCentavos) maxFeeCentavos = maximum;
  }

  /// The platform fee for one distance.
  ///
  /// An unknown distance still earns the minimum: the floor is a contract term,
  /// not a distance measurement, so charging it does not require inventing a
  /// route.
  static int platformFee(TripDistance distance) {
    if (!distance.isMeasured) return minFeeCentavos;
    final metres = (distance.kilometres * 1000).round();
    final raw = (metres * perKmFeeCentavos + 500) ~/ 1000;
    return raw.clamp(minFeeCentavos, maxFeeCentavos);
  }

  static RidePrice price({
    required int providerFare,
    required TripDistance distance,
  }) =>
      RidePrice(
        providerFare: providerFare,
        platformFee: platformFee(distance),
        distance: distance,
      );

  /// Prices a request the way settlement will, from the fields it carries.
  ///
  /// A request created in this session has coordinates and is priced on the
  /// straight line between them; a seeded request is priced on the distance it
  /// was seeded with. Both are mock distances, and both say so.
  static RidePrice forRequest({
    required int providerFare,
    double? seededKilometres,
    MapPoint? pickup,
    MapPoint? dropoff,
  }) {
    final direct = TripDistance.between(pickup, dropoff);
    final distance = direct.isMeasured
        ? direct
        : (seededKilometres == null || seededKilometres <= 0
            ? TripDistance.unknown
            : TripDistance.seeded(seededKilometres));
    return price(providerFare: providerFare, distance: distance);
  }

  /// The same money written as the split every receipt already renders.
  ///
  /// [FeeBreakdown.providerGets] is the full fare and
  /// [FeeBreakdown.surgoKeeps] is the platform fee, so the Pasuyo and rental
  /// screens need no special case to show a ride — but the basis says the two
  /// were earned differently, and the revenue screen must not read a ride's
  /// fee as a percentage of its fare.
  static FeeBreakdown breakdown(RidePrice price) => FeeBreakdown.distanceFee(
        providerFare: price.providerFare,
        platformFee: price.platformFee,
      );
}
