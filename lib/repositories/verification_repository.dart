import 'dart:typed_data';

import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// The database token for a capability. `verification_applications` only
/// accepts the three provider roles, so passenger is deliberately absent.
String verificationCapabilityToken(CapabilityType capability) =>
    switch (capability) {
      CapabilityType.passenger => 'passenger',
      CapabilityType.earner => 'earner',
      CapabilityType.rider => 'rider',
      CapabilityType.vehicleOwner => 'vehicle_owner',
    };

/// One file a user picked for a verification document, still in memory.
///
/// The repository uploads it and records the storage path; the screen never
/// writes a path itself, so a document cannot point outside the user's folder.
class VerificationUpload {
  const VerificationUpload({
    required this.documentType,
    required this.label,
    required this.fileName,
    required this.bytes,
    this.documentNumber,
    this.expiresAt,
  });

  final String documentType;
  final String label;
  final String fileName;
  final Uint8List bytes;
  final String? documentNumber;
  final DateTime? expiresAt;

  /// MIME type from the file name. The bucket only accepts these three types,
  /// so an unknown extension is refused before a doomed upload is started.
  String get contentType {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    throw RepositoryFailure.invalidData(
      'Choose a PDF, PNG or JPEG file for ${label.isEmpty ? documentType : label}.',
    );
  }
}

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

  /// Uploads [documents] and submits one application for [capability].
  ///
  /// The auth server checks ownership and sets the status; this method cannot
  /// submit an approved role or write for another profile.
  Future<VerificationApplicationRecord> submitApplication({
    required String profileId,
    required String capability,
    required List<VerificationUpload> documents,
  });
}

const String _applicationColumns =
    'id, profile_id, capability_type, status, submitted_at, reviewed_at, '
    'decided_at, rejection_reason, '
    'documents:verification_documents(id, application_id, document_type, '
    'label, document_number, storage_path, expires_at, is_required, status, '
    'rejection_reason)';

class SupabaseVerificationRepository implements VerificationRepository {
  SupabaseVerificationRepository(SurgoBackend backend, {this._writer})
      : _backend = backend;

  /// Private bucket; object paths must start with the owner's auth uuid for the
  /// storage policies to accept them.
  static const String bucket = 'verification-documents';

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;

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

  @override
  Future<VerificationApplicationRecord> submitApplication({
    required String profileId,
    required String capability,
    required List<VerificationUpload> documents,
  }) async {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot submit verification documents.',
      );
    }
    if (documents.isEmpty) {
      throw RepositoryFailure.invalidData(
        'Attach every required document before submitting.',
      );
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final payload = <Map<String, dynamic>>[];
    // Uploads happen before the RPC, so a refusal leaves these objects behind.
    // Deleting them here on failure would be unsafe: a timeout can hide a
    // submission the server already committed, and deleting its files would
    // leave a valid application pointing at nothing. Orphan cleanup belongs to
    // a service-role maintenance job, not the applicant's client.
    for (var index = 0; index < documents.length; index++) {
      final document = documents[index];
      // Throws for an extension the bucket will not accept, before any upload.
      final contentType = document.contentType;
      final extension = switch (contentType) {
        'application/pdf' => 'pdf',
        'image/png' => 'png',
        _ => 'jpg',
      };
      final type = document.documentType.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '',
      );
      // `<uid>/...` is required by the bucket policy; the server repeats the
      // check so a tampered path cannot file a document under another person.
      final path = '$profileId/$capability/$type-$stamp-$index.$extension';
      await writer.uploadObject(
        bucket: bucket,
        path: path,
        bytes: document.bytes,
        contentType: contentType,
      );
      payload.add({
        'document_type': document.documentType,
        'label': document.label,
        'document_number': document.documentNumber,
        'expires_at': document.expiresAt
            ?.toIso8601String()
            .substring(0, 10),
        'storage_path': path,
      });
    }

    final result = await writer.rpc(
      function: 'submit_verification_application',
      params: {'p_capability': capability, 'p_documents': payload},
    );
    final applicationId = result is String ? result : '$result';
    final record = await fetchApplication(applicationId);
    if (record == null) {
      throw RepositoryFailure.invalidData(
        'The application was submitted but could not be read back.',
      );
    }
    return record;
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

  @override
  Future<VerificationApplicationRecord> submitApplication({
    required String profileId,
    required String capability,
    required List<VerificationUpload> documents,
  }) {
    // The offline demo keeps its own flow in AppState; writing a real
    // application from a seed account would put a fake row in a real pipeline.
    throw RepositoryFailure.unsupported(
      'Verification submission is simulated in the offline demo.',
    );
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
