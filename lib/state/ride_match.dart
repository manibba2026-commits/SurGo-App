import '../data/db_models.dart';
import 'ride_status.dart';

/// A rider the platform is considering for a request, before either side has
/// committed.
///
/// This exists so that "we found someone" is a thing the app can hold and
/// show, distinct from [RideStatus.accepted]. Without a separate value for the
/// proposal, a match has nowhere to live between `searching` and the rider's
/// yes, and the UI is pushed into treating the match as the acceptance.
class RideMatchProposal {
  /// The rider being proposed, from the seeded fleet.
  final MapRider rider;

  /// Which request this proposal is for.
  final String requestId;

  /// Straight-line distance to the pickup, in km. Null when either point is
  /// missing coordinates, in which case the UI shows "Nearby" instead of a
  /// number it cannot stand behind.
  final double? distanceKm;

  /// Minutes until this rider could reach the pickup.
  final int etaMinutes;

  /// What the passenger pays for this trip, in centavos.
  final int fare;

  const RideMatchProposal({
    required this.rider,
    required this.requestId,
    required this.etaMinutes,
    required this.fare,
    this.distanceKm,
  });

  /// Two-letter monogram for the avatar, from the rider's name.
  ///
  /// Uses `substring(0, 1)` rather than grapheme-aware access: `characters` is
  /// not a direct dependency of this package, and a rider's seeded name is
  /// plain ASCII.
  String get initials {
    final parts = rider.name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  /// Distance for display, or a word when the seed has no coordinates.
  String get distanceLabel => distanceKm == null
      ? 'Nearby'
      : '${distanceKm!.toStringAsFixed(1)} km away';

  /// Name for the proposal card.
  String get riderName => rider.name;

  /// Vehicle description, e.g. "Tricycle · Honda TMX".
  String get vehicleLabel => rider.vehicleModel.trim().isEmpty
      ? rider.vehicleType
      : '${rider.vehicleType} · ${rider.vehicleModel}';

  /// The two letters SurGo uses as a placeholder plate when the seed has no
  /// real one. Shown as a monogram rather than invented digits, because a
  /// made-up plate number reads as a real vehicle record.
  String get plateLabel => rider.vehicleType.toUpperCase();
}

/// How the proposal was resolved. Kept as a typed result so the matching screen
/// can explain a failure instead of showing an empty state.
enum MatchOutcome {
  /// A rider was found and proposed.
  proposed,

  /// Nobody was available. Distinct from "found but the passenger declined",
  /// which is a normal outcome rather than a failure to match.
  noRidersAvailable,
}