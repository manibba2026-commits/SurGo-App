import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_failure.dart';
import 'package:surgo/repositories/verification_repository.dart';

/// Pins the submit path to the contract the hosted schema enforces: every file
/// is uploaded into the user's own folder of the private bucket, the recorded
/// storage path is the uploaded one, and nothing is written when validation
/// fails. The database still owns approval; this layer only files the request.
void main() {
  group('submitting a verification application', () {
    test('uploads each document under the applicant and records its path',
        () async {
      final backend = _FakeBackend();

      final record = await backend.repository.submitApplication(
        profileId: 'user-1',
        capability: 'rider',
        documents: [
          _upload('valid_id', 'ID front', 'id.pdf'),
          _upload('selfie', 'Selfie', 'face.jpg'),
        ],
      );

      expect(backend.uploads, hasLength(2));
      for (final upload in backend.uploads) {
        expect(upload.bucket, SupabaseVerificationRepository.bucket);
        expect(upload.path, startsWith('user-1/rider/'),
            reason: 'the bucket policy only allows the applicant\'s folder');
      }
      expect(backend.uploads[0].contentType, 'application/pdf');
      expect(backend.uploads[1].contentType, 'image/jpeg');

      final call = backend.calls.single;
      expect(call.function, 'submit_verification_application');
      expect(call.params['p_capability'], 'rider');
      final documents = call.params['p_documents'] as List<dynamic>;
      expect(documents, hasLength(2));
      expect(
        documents.map((d) => (d as Map)['storage_path']),
        backend.uploads.map((u) => u.path),
        reason: 'the row must point at the object that was actually uploaded',
      );
      expect(documents.first['document_type'], 'valid_id');
      expect(documents.first['label'], 'ID front');

      // The application is read back after the RPC, so the screen shows what
      // the server stored rather than a locally invented status.
      expect(record.id, 'app-1');
      expect(record.profileId, 'user-1');
      expect(record.capabilityType, 'rider');
      expect(record.status, 'submitted');
    });

    test('keeps the document number and expiry date on the row', () async {
      final backend = _FakeBackend();

      await backend.repository.submitApplication(
        profileId: 'user-1',
        capability: 'vehicle_owner',
        documents: [
          _upload(
            'or_cr',
            'OR / CR',
            'registration.png',
            documentNumber: 'OR-4451',
            expiresAt: DateTime(2027, 3, 31),
          ),
        ],
      );

      final document =
          (backend.calls.single.params['p_documents'] as List).single as Map;
      expect(document['document_number'], 'OR-4451');
      expect(document['expires_at'], '2027-03-31');
      expect(backend.uploads.single.contentType, 'image/png');
    });

    test('refuses an empty document set before touching storage', () async {
      final backend = _FakeBackend();

      await expectLater(
        backend.repository.submitApplication(
          profileId: 'user-1',
          capability: 'rider',
          documents: const [],
        ),
        throwsA(isA<RepositoryFailure>().having(
          (f) => f.kind,
          'kind',
          RepositoryFailureKind.invalidData,
        )),
      );
      expect(backend.uploads, isEmpty);
      expect(backend.calls, isEmpty);
    });

    test('refuses an unsupported file before uploading anything', () async {
      final backend = _FakeBackend();

      await expectLater(
        backend.repository.submitApplication(
          profileId: 'user-1',
          capability: 'rider',
          documents: [_upload('valid_id', 'ID front', 'id.txt')],
        ),
        throwsA(isA<RepositoryFailure>().having(
          (f) => f.kind,
          'kind',
          RepositoryFailureKind.invalidData,
        )),
      );
      expect(backend.uploads, isEmpty);
      expect(backend.calls, isEmpty);
    });

    test('a read-only backend cannot submit', () async {
      final backend = _FakeBackend(writable: false);

      await expectLater(
        backend.repository.submitApplication(
          profileId: 'user-1',
          capability: 'rider',
          documents: [_upload('valid_id', 'ID front', 'id.pdf')],
        ),
        throwsA(isA<RepositoryFailure>().having(
          (f) => f.kind,
          'kind',
          RepositoryFailureKind.unsupported,
        )),
      );
      expect(backend.uploads, isEmpty);
    });
  });

  group('reading the review decision', () {
    test('a needs-resubmission decision carries its reason to the screen',
        () async {
      final backend = _FakeBackend(
        storedStatus: 'needs_resubmission',
        storedReason: 'The selfie is blurred. Retake it in daylight.',
      );

      final record = await backend.repository
          .fetchApplication('app-1');

      expect(record, isNotNull);
      expect(record!.status, 'needs_resubmission');
      expect(record.rejectionReason,
          'The selfie is blurred. Retake it in daylight.');
      expect(record.documents.single.documentType, 'valid_id');
    });

    test('an approved decision is read from the server, not assumed', () async {
      final backend = _FakeBackend(storedStatus: 'approved');

      final record = await backend.repository.fetchApplication('app-1');

      expect(record!.status, 'approved');
      expect(record.rejectionReason, isNull);
    });

    test('another user\'s application cannot be reached through the folder',
        () async {
      final backend = _FakeBackend();

      await backend.repository.submitApplication(
        profileId: 'user-1',
        capability: 'rider',
        documents: [_upload('valid_id', 'ID front', 'id.pdf')],
      );

      for (final upload in backend.uploads) {
        expect(upload.path.split('/').first, 'user-1');
        expect(upload.path, isNot(contains('user-2/')));
      }
    });
  });
}

VerificationUpload _upload(
  String type,
  String label,
  String fileName, {
  String? documentNumber,
  DateTime? expiresAt,
}) =>
    VerificationUpload(
      documentType: type,
      label: label,
      fileName: fileName,
      bytes: Uint8List.fromList([1, 2, 3]),
      documentNumber: documentNumber,
      expiresAt: expiresAt,
    );

class _Upload {
  _Upload({
    required this.bucket,
    required this.path,
    required this.bytes,
    required this.contentType,
  });

  final String bucket;
  final String path;
  final Uint8List bytes;
  final String contentType;
}

class _RpcCall {
  _RpcCall(this.function, this.params);

  final String function;
  final Map<String, dynamic> params;
}

/// A backend that records writes instead of reaching Supabase.
class _FakeBackend implements SurgoBackend, SurgoWriteBackend {
  _FakeBackend({
    bool writable = true,
    this.storedStatus = 'submitted',
    this.storedReason,
  }) : _writable = writable;
  final bool _writable;

  final String storedStatus;
  final String? storedReason;

  final List<_Upload> uploads = [];
  final List<_RpcCall> calls = [];

  VerificationRepository get repository => SupabaseVerificationRepository(
        this,
        writer: _writable ? this : null,
      );

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final id = eq['id'] ?? 'app-1';
    return {
      'id': id,
      'profile_id': 'user-1',
      'capability_type': 'rider',
      'status': storedStatus,
      'submitted_at': '2026-11-10T08:00:00Z',
      'reviewed_at': storedReason == null ? null : '2026-11-10T09:00:00Z',
      'decided_at': null,
      'rejection_reason': storedReason,
      'documents': [
        {
          'id': 'doc-1',
          'application_id': id,
          'document_type': 'valid_id',
          'label': 'ID front',
          'document_number': null,
          'storage_path': uploads.isEmpty ? null : uploads.first.path,
          'expires_at': null,
          'is_required': true,
          'status': 'pending',
          'rejection_reason': null,
        },
      ],
    };
  }

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) async {
    calls.add(_RpcCall(function, params));
    return 'app-1';
  }

  @override
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    uploads.add(_Upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: contentType,
    ));
  }
}
