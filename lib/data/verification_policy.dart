import 'db_models.dart';

/// One document SurGo requires for a [CapabilityType] verification application.
class VerificationDocSpec {
  final String id;
  final String label;
  final String hint;
  final bool required;

  const VerificationDocSpec({
    required this.id,
    required this.label,
    required this.hint,
    this.required = true,
  });
}

/// The rules for getting approved for each [CapabilityType] in the demo.
///
/// Kept in code rather than the seed because it defines behaviour, not data,
/// and it is the single source both the verification screen and
/// [AppState]'s application builder read — a requirement can never drift out
/// of sync between the checklist on screen and the application created for it.
class VerificationPolicy {
  VerificationPolicy._();

  /// How long after submission the pipeline flips Submitted -> Under review.
  static const Duration submittedUnderReview = Duration(seconds: 2);

  /// How long after submission (not after passing review) the demo
  /// auto-approves. One visible "under review" beat before the approval lands.
  static const Duration underReviewApproval = Duration(seconds: 5);

  /// The documents required to apply for [capability], in checklist order.
  static List<VerificationDocSpec> requirementsFor(CapabilityType capability) {
    switch (capability) {
      case CapabilityType.rider:
        return const [
          VerificationDocSpec(
            id: 'dl',
            label: 'Driver\'s license',
            hint: 'Valid non-professional or professional driver\'s license, '
                'front and back.',
          ),
          VerificationDocSpec(
            id: 'orcr',
            label: 'Vehicle OR/CR',
            hint: 'Official Receipt and Certificate of Registration for the '
                'vehicle you will drive.',
          ),
        ];
      case CapabilityType.vehicleOwner:
        return const [
          VerificationDocSpec(
            id: 'orcr',
            label: 'Vehicle OR/CR',
            hint: 'Official Receipt and Certificate of Registration for each '
                'vehicle you will list.',
          ),
          VerificationDocSpec(
            id: 'insurance',
            label: 'Motor insurance policy',
            hint:
                'Comprehensive or third-party insurance covering the vehicles '
                'you will rent out.',
          ),
          VerificationDocSpec(
            id: 'permit',
            label: 'Rental business permit',
            hint: 'Barangay or municipal permit authorizing vehicle rentals.',
          ),
        ];
      case CapabilityType.earner:
        return const [
          VerificationDocSpec(
            id: 'id',
            label: 'Government-issued ID',
            hint: 'Valid government-issued photo ID, front and back.',
          ),
          VerificationDocSpec(
            id: 'clearance',
            label: 'Barangay clearance',
            hint: 'Barangay clearance issued within the last 6 months.',
          ),
        ];
      case CapabilityType.passenger:
        return const [];
    }
  }
}
