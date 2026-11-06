import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';

/// Verification applications and their documents.
///
/// Separate from [ProfileRepository.fetchVerificationApplications] because the
/// verification screen needs to fetch one application and its documents without
/// reloading the whole profile. Both read the same rows.
abstract interface class VerificationRepository {
  /// Every application for [profileId], newest first.
  Future<List<VerificationApplicationRecord>> fetchApplications(
    String profileId,
  );

  Future<VerificationApplicationRecord?> fetchApplication(String applicationId);

  Future<List<VerificationDocumentRecord>> fetchDocuments(
    String applicationId,
  );
}

const String _applicationColumns =
    'id, profile_id, capability_type, status, submitted_at, reviewed_at, '
    'decided_at, rejection_reason, '
    'documents:verification_documents(id, application_id, document_type, '
    'label, document_number, storage_path, expires_at, is_required, status, '
    'rejection_reason)';

class SupabaseVerificationRepository implements VerificationRepository {
  SupabaseVerificationRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<VerificationApplicationRecord>> fetchApplications(
    String profileId,
  ) async {
    final rows = await _backend.rows(
      table: 'verification_applications',
      columns: _applicationColumns,
      eq: {'profile_id': profileId},
      orderBy: 'created_at',
    );
    return [for (final row in rows) VerificationApplicationRecord.fromRow(row)];
  }

  @override
  Future<VerificationApplicationRecord?> fetchApplication(
    String applicationId,
  ) async {
    final row = await _backend.row(
      table: 'verification_applications',
      columns: _applicationColumns,
      eq: {'id': applicationId},
    );
    return row == null ? null : VerificationApplicationRecord.fromRow(row);
  }

  @override
  Future<List<VerificationDocumentRecord>> fetchDocuments(
    String applicationId,
  ) async {
    final rows = await _backend.rows(
      table: 'verification_documents',
      columns: 'id, application_id, document_type, label, document_number, '
          'storage_path, expires_at, is_required, status, rejection_reason',
      eq: {'application_id': applicationId},
      orderBy: 'created_at',
      ascending: true,
    );
    return [for (final row in rows) VerificationDocumentRecord.fromRow(row)];
  }
}

/// Reads the seeded `applications.json` slice.
///
/// The seed identifies an application by the demo account (`ACC002`), while a
/// signed-in session carries a Supabase uuid. [profileId] is resolved through
/// the account relationship first, so both shapes work.
class MockVerificationRepository implements VerificationRepository {
  MockVerificationRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<VerificationApplicationRecord>> fetchApplications(
    String profileId,
  ) async {
    final account = _accountFor(profileId);
    if (account == null) return const [];
    return [
      for (final application in _db.verificationApplications)
        if (application.accountId == account.id) _toRecord(application),
    ];
  }

  @override
  Future<VerificationApplicationRecord?> fetchApplication(
    String applicationId,
  ) async {
    for (final application in _db.verificationApplications) {
      if (application.id == applicationId) return _toRecord(application);
    }
    return null;
  }

  @override
  Future<List<VerificationDocumentRecord>> fetchDocuments(
    String applicationId,
  ) async {
    final application = await fetchApplication(applicationId);
    return application?.documents ?? const [];
  }

  Account? _accountFor(String profileId) {
    for (final account in _db.accounts) {
      if (account.id == profileId ||
          account.passengerId == profileId ||
          account.riderId == profileId ||
          account.ownerId == profileId) {
        return account;
      }
    }
    return _db.findAccountForIdentity(authUserId: profileId);
  }

  VerificationApplicationRecord _toRecord(
    VerificationApplication application,
  ) {
    final capability = application.capabilityType;
    return VerificationApplicationRecord(
      id: application.id,
      profileId: application.accountId,
      capabilityType: _capabilityToken(capability),
      status: _dbStatus(application.status),
      submittedAt: application.submittedAt,
      reviewedAt: application.reviewedAt,
      decidedAt: application.status == VerificationStatus.approved ||
              application.status == VerificationStatus.rejected
          ? application.reviewedAt
          : null,
      rejectionReason: application.status == VerificationStatus.rejected
          ? application.reviewerNote
          : null,
      documents: [
        for (final document in application.documents)
          VerificationDocumentRecord(
            id: document.id,
            applicationId: application.id,
            documentType: document.id,
            label: document.label,
            status: document.uploaded ? 'approved' : 'pending',
            isRequired: document.required,
          ),
      ],
    );
  }

  static String _capabilityToken(CapabilityType capability) =>
      switch (capability) {
        CapabilityType.passenger => 'passenger',
        CapabilityType.earner => 'earner',
        CapabilityType.rider => 'rider',
        CapabilityType.vehicleOwner => 'vehicle_owner',
      };

  static String _dbStatus(VerificationStatus status) => switch (status) {
        VerificationStatus.draft => 'draft',
        VerificationStatus.submitted => 'submitted',
        VerificationStatus.underReview => 'under_review',
        VerificationStatus.approved => 'approved',
        VerificationStatus.rejected => 'rejected',
        VerificationStatus.needsResubmission => 'needs_resubmission',
      };
}
