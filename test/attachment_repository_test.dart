import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/repositories/attachment_repository.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_failure.dart';

/// Pins the upload path to the contract the hosted schema enforces: bytes go
/// into the owner's own folder of the private bucket, the metadata row is
/// written by an RPC, and a failed registration removes the orphaned object
/// rather than leaving a file nothing points at.
void main() {
  group('uploading an attachment', () {
    test('files the bytes under the owner and records the real metadata',
        () async {
      final backend = _FakeBackend();

      final record = await backend.repository.uploadAttachment(
        ownerProfileId: 'user-1',
        file: _upload('Q4 report.pdf', label: 'Q4 report'),
        onStage: backend.stages.add,
      );

      final upload = backend.uploads.single;
      expect(upload.bucket, SupabaseAttachmentRepository.bucket);
      expect(upload.path, startsWith('user-1/'),
          reason: 'the bucket policy only allows the owner folder');
      expect(upload.contentType, 'application/pdf');

      final call = backend.calls.single;
      expect(call.function, 'register_attachment');
      expect(call.params['p_owner_profile_id'], 'user-1');
      expect(call.params['p_storage_path'], upload.path);
      expect(call.params['p_file_name'], 'Q4 report.pdf');
      expect(call.params['p_mime_type'], 'application/pdf');
      expect(call.params['p_size_bytes'], 3);
      expect(call.params['p_label'], 'Q4 report');

      expect(record.id, 'att-1');
      expect(record.storagePath, upload.path);
      expect(record.category, 'document');
      expect(backend.stages, [
        AttachmentUploadStage.uploading,
        AttachmentUploadStage.recording,
      ]);
    });

    test('refuses an unsupported extension before touching storage', () async {
      final backend = _FakeBackend();

      await expectLater(
        backend.repository.uploadAttachment(
          ownerProfileId: 'user-1',
          file: _upload('setup.exe'),
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

    test('refuses a file over 20 MB before touching storage', () async {
      final backend = _FakeBackend();

      await expectLater(
        backend.repository.uploadAttachment(
          ownerProfileId: 'user-1',
          file: AttachmentUpload(
            fileName: 'huge.mp4',
            bytes: Uint8List(attachmentMaxBytes + 1),
          ),
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

    test('removes the uploaded object when the metadata write fails', () async {
      final backend = _FakeBackend(failRegister: true);

      await expectLater(
        backend.repository.uploadAttachment(
          ownerProfileId: 'user-1',
          file: _upload('report.pdf'),
        ),
        throwsA(isA<RepositoryFailure>()),
      );

      expect(backend.uploads, hasLength(1));
      expect(backend.removed, [backend.uploads.single.path]);
    });

    test('a read-only backend cannot upload', () async {
      final backend = _FakeBackend(writable: false);

      await expectLater(
        backend.repository.uploadAttachment(
          ownerProfileId: 'user-1',
          file: _upload('report.pdf'),
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

  group('replacing and deleting', () {
    test('replace points the row at the new object and removes the old bytes',
        () async {
      final backend = _FakeBackend();
      final original = _record(id: 'att-1', path: 'user-1/old.pdf');

      final updated = await backend.repository.replaceAttachment(
        attachment: original,
        file: _upload('new.pdf'),
      );

      final upload = backend.uploads.single;
      expect(upload.path, isNot(original.storagePath));
      expect(backend.calls.single.function, 'replace_attachment');
      expect(backend.calls.single.params['p_attachment_id'], 'att-1');
      expect(backend.removed, [original.storagePath]);
      expect(updated.storagePath, upload.path);
    });

    test('delete removes the metadata row and then the returned object',
        () async {
      final backend = _FakeBackend();
      final record = _record(id: 'att-1', path: 'user-1/old.pdf');

      await backend.repository.deleteAttachment(record);

      expect(backend.calls.single.function, 'delete_attachment');
      expect(backend.calls.single.params['p_attachment_id'], 'att-1');
      expect(backend.removed, ['user-1/old.pdf']);
    });

    test('signedUrl asks for a short-lived link to the stored object',
        () async {
      final backend = _FakeBackend();
      final record = _record(id: 'att-1', path: 'user-1/old.pdf');

      final url = await backend.repository.signedUrl(record);

      expect(url, 'https://signed.example/user-1/old.pdf');
      expect(backend.signedRequests.single,
          (SupabaseAttachmentRepository.bucket, 'user-1/old.pdf'));
    });
  });

  group('offline demo', () {
    test('has no files and refuses every write instead of faking one',
        () async {
      const repository = MockAttachmentRepository();

      expect(await repository.fetchAttachments('acc-1'), isEmpty);
      expect(
        () => repository.uploadAttachment(
          ownerProfileId: 'acc-1',
          file: _upload('report.pdf'),
        ),
        throwsA(isA<RepositoryFailure>().having(
          (f) => f.kind,
          'kind',
          RepositoryFailureKind.unsupported,
        )),
      );
      expect(
        () => repository.deleteAttachment(
          _record(id: 'att-1', path: 'acc-1/old.pdf'),
        ),
        throwsA(isA<RepositoryFailure>().having(
          (f) => f.kind,
          'kind',
          RepositoryFailureKind.unsupported,
        )),
      );
    });
  });
}

AttachmentUpload _upload(String fileName, {String? label}) => AttachmentUpload(
      fileName: fileName,
      bytes: Uint8List.fromList([1, 2, 3]),
      label: label,
    );

AttachmentRecord _record({required String id, required String path}) =>
    AttachmentRecord(
      id: id,
      ownerProfileId: 'user-1',
      bucketId: 'attachments',
      storagePath: path,
      fileName: 'old.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 3,
      category: 'document',
      uploadedBy: 'user-1',
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

/// A backend that records storage and RPC calls instead of reaching Supabase.
class _FakeBackend
    implements SurgoBackend, SurgoWriteBackend, SurgoStorageBackend {
  _FakeBackend({this._writable = true, this.failRegister = false});

  final bool _writable;
  final bool failRegister;

  final List<_Upload> uploads = [];
  final List<_RpcCall> calls = [];
  final List<String> removed = [];
  final List<(String, String)> signedRequests = [];
  final List<AttachmentUploadStage> stages = [];

  AttachmentRepository get repository => SupabaseAttachmentRepository(
        this,
        writer: _writable ? this : null,
        storage: this,
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
    final upload = uploads.isEmpty ? null : uploads.last;
    final id = eq['id'] ?? 'att-1';
    return {
      'id': id,
      'owner_profile_id': 'user-1',
      'bucket_id': 'attachments',
      'storage_path': upload?.path ?? 'user-1/old.pdf',
      'file_name': 'report.pdf',
      'mime_type': upload?.contentType ?? 'application/pdf',
      'size_bytes': upload?.bytes.length ?? 3,
      'category': 'document',
      'label': null,
      'uploaded_by': 'user-1',
      'created_at': '2026-11-11T08:00:00Z',
      'updated_at': '2026-11-11T08:00:00Z',
    };
  }

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) async {
    calls.add(_RpcCall(function, params));
    if (function == 'register_attachment' && failRegister) {
      throw RepositoryFailure.invalidData('the uploaded file was not found');
    }
    if (function == 'replace_attachment') return 'user-1/old.pdf';
    if (function == 'delete_attachment') return 'user-1/old.pdf';
    return 'att-1';
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

  @override
  Future<void> removeObject({
    required String bucket,
    required String path,
  }) async {
    removed.add(path);
  }

  @override
  Future<String> signedObjectUrl({
    required String bucket,
    required String path,
    Duration expiresIn = const Duration(minutes: 5),
  }) async {
    signedRequests.add((bucket, path));
    return 'https://signed.example/$path';
  }
}
