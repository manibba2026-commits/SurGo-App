import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// The default per-file limit. The bucket, the table check constraint and the
/// RPCs all enforce the same 20 MB, so a client cannot raise it.
const int attachmentMaxBytes = 20 * 1024 * 1024;

/// Extensions the bucket accepts, grouped the way the picker shows them.
///
/// SVG is deliberately absent: a signed URL can render it as an active document
/// in a browser. The server keeps the same allowlist; this list only keeps a
/// doomed upload from starting.
const List<String> attachmentAllowedExtensions = [
  // documents
  'pdf', 'doc', 'docx', 'rtf', 'txt',
  // spreadsheets
  'xls', 'xlsx', 'csv',
  // presentations
  'ppt', 'pptx',
  // images (raster only)
  'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif', 'bmp', 'tiff', 'tif',
  // archives
  'zip',
  // audio
  'mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac', 'weba',
  // video
  'mp4', 'webm', 'mov', 'avi', 'mkv', 'mpeg', 'mpg', '3gp',
];

const Map<String, String> _mimeByExtension = {
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'rtf': 'application/rtf',
  'txt': 'text/plain',
  'xls': 'application/vnd.ms-excel',
  'xlsx':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'csv': 'text/csv',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'tiff': 'image/tiff',
  'tif': 'image/tiff',
  'zip': 'application/zip',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'weba': 'audio/webm',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'avi': 'video/x-msvideo',
  'mkv': 'video/x-matroska',
  'mpeg': 'video/mpeg',
  'mpg': 'video/mpeg',
  '3gp': 'video/3gpp',
};

/// The MIME type for [fileName], or a typed failure for an extension the
/// bucket will not accept.
String attachmentContentTypeFor(String fileName) {
  final extension = _extensionOf(fileName);
  final mime = _mimeByExtension[extension];
  if (mime == null) {
    throw RepositoryFailure.invalidData(
      'That file type is not supported. Choose a document, spreadsheet, '
      'presentation, image, archive, audio or video file.',
    );
  }
  return mime;
}

/// One file picked for upload, still in memory.
///
/// The repository, not the screen, chooses the storage path, so a caller cannot
/// file bytes under another account's folder.
class AttachmentUpload {
  const AttachmentUpload({
    required this.fileName,
    required this.bytes,
    this.label,
  });

  final String fileName;
  final Uint8List bytes;
  final String? label;

  /// Validates the extension and returns the MIME type the bucket expects.
  String get contentType => attachmentContentTypeFor(fileName);

  /// A safe display name: no path separators, never empty, at most 255 chars.
  String get safeFileName {
    final base = fileName.split(RegExp(r'[\\/]')).last.trim();
    final cleaned = base.isEmpty ? 'file' : base;
    return cleaned.length <= 255 ? cleaned : cleaned.substring(0, 255);
  }
}

/// Where an upload is in its two real stages.
enum AttachmentUploadStage {
  /// Bytes are travelling to private storage.
  uploading,

  /// Bytes are stored; the metadata row is being recorded.
  recording,
}

/// Private user files: list, signed link, upload, replace and delete.
///
/// The database is the authority on ownership and file rules. Every write goes
/// through an RPC that checks the signed-in account, the 20 MB limit, the MIME
/// allowlist and that the object actually exists in storage.
abstract interface class AttachmentRepository {
  Future<List<AttachmentRecord>> fetchAttachments(String ownerProfileId);

  /// A short-lived link for [attachment]. Never cached by the app.
  Future<String> signedUrl(
    AttachmentRecord attachment, {
    Duration expiresIn = const Duration(minutes: 5),
  });

  Future<AttachmentRecord> uploadAttachment({
    required String ownerProfileId,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  });

  /// Uploads [file] as the new contents of [attachment] and returns the updated
  /// row. The previous object is removed after the metadata update succeeds.
  Future<AttachmentRecord> replaceAttachment({
    required AttachmentRecord attachment,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  });

  /// Deletes the metadata row, then the stored object.
  Future<void> deleteAttachment(AttachmentRecord attachment);
}

const String _columns = 'id, owner_profile_id, bucket_id, storage_path, '
    'file_name, mime_type, size_bytes, category, label, uploaded_by, '
    'created_at, updated_at';

class SupabaseAttachmentRepository implements AttachmentRepository {
  SupabaseAttachmentRepository(
    SurgoBackend backend, {
    SurgoWriteBackend? writer,
    SurgoStorageBackend? storage,
  })  : _backend = backend,
        _writer = writer,
        _storage = storage;

  /// Private bucket. Object names are `<owner_profile_id>/<unique>.<ext>`.
  static const String bucket = 'attachments';

  final SurgoBackend _backend;
  final SurgoWriteBackend? _writer;
  final SurgoStorageBackend? _storage;

  @override
  Future<List<AttachmentRecord>> fetchAttachments(String ownerProfileId) async {
    final rows = await _backend.rows(
      table: 'attachments',
      columns: _columns,
      eq: {'owner_profile_id': ownerProfileId},
      orderBy: 'created_at',
    );
    return [for (final row in rows) AttachmentRecord.fromRow(row)];
  }

  @override
  Future<String> signedUrl(
    AttachmentRecord attachment, {
    Duration expiresIn = const Duration(minutes: 5),
  }) {
    final storage = _storage;
    if (storage == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot open private files.',
      );
    }
    return storage.signedObjectUrl(
      bucket: attachment.bucketId,
      path: attachment.storagePath,
      expiresIn: expiresIn,
    );
  }

  @override
  Future<AttachmentRecord> uploadAttachment({
    required String ownerProfileId,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  }) async {
    final writer = _requireWriter();
    final prepared = _prepare(ownerProfileId, file);

    onStage?.call(AttachmentUploadStage.uploading);
    await writer.uploadObject(
      bucket: bucket,
      path: prepared.path,
      bytes: file.bytes,
      contentType: prepared.contentType,
    );

    onStage?.call(AttachmentUploadStage.recording);
    final dynamic result;
    try {
      result = await writer.rpc(
        function: 'register_attachment',
        params: {
          'p_owner_profile_id': ownerProfileId,
          'p_storage_path': prepared.path,
          'p_file_name': file.safeFileName,
          'p_mime_type': prepared.contentType,
          'p_size_bytes': file.bytes.length,
          'p_label': _cleanLabel(file.label),
        },
      );
    } catch (error) {
      // The metadata row was not written, so the uploaded object is an orphan.
      // Removing it here is safe: the RPC never committed.
      await _removeQuietly(prepared.path);
      rethrow;
    }

    final id = result is String ? result : '$result';
    final row = await _backend.row(
      table: 'attachments',
      columns: _columns,
      eq: {'id': id},
    );
    if (row == null) {
      // The row exists (the RPC committed); only the read-back failed. Do not
      // delete the object, or the row would point at nothing.
      throw RepositoryFailure.invalidData(
        'The file was saved but could not be read back. Reopen this screen.',
      );
    }
    return AttachmentRecord.fromRow(row);
  }

  @override
  Future<AttachmentRecord> replaceAttachment({
    required AttachmentRecord attachment,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  }) async {
    final writer = _requireWriter();
    final prepared = _prepare(attachment.ownerProfileId, file);

    onStage?.call(AttachmentUploadStage.uploading);
    await writer.uploadObject(
      bucket: bucket,
      path: prepared.path,
      bytes: file.bytes,
      contentType: prepared.contentType,
    );

    onStage?.call(AttachmentUploadStage.recording);
    final dynamic result;
    try {
      result = await writer.rpc(
        function: 'replace_attachment',
        params: {
          'p_attachment_id': attachment.id,
          'p_storage_path': prepared.path,
          'p_file_name': file.safeFileName,
          'p_mime_type': prepared.contentType,
          'p_size_bytes': file.bytes.length,
          'p_label': _cleanLabel(file.label),
        },
      );
    } catch (error) {
      // The row still points at the old object, so remove the new upload.
      await _removeQuietly(prepared.path);
      rethrow;
    }

    final previous = result is String ? result : '$result';
    if (previous.isNotEmpty && previous != prepared.path) {
      // The metadata update committed; the old bytes are now unreferenced.
      await _removeQuietly(previous);
    }

    final row = await _backend.row(
      table: 'attachments',
      columns: _columns,
      eq: {'id': attachment.id},
    );
    if (row == null) {
      throw RepositoryFailure.invalidData(
        'The file was replaced but could not be read back. Reopen this screen.',
      );
    }
    return AttachmentRecord.fromRow(row);
  }

  @override
  Future<void> deleteAttachment(AttachmentRecord attachment) async {
    final writer = _requireWriter();
    final dynamic result = await writer.rpc(
      function: 'delete_attachment',
      params: {'p_attachment_id': attachment.id},
    );
    final path = result is String && result.isNotEmpty
        ? result
        : attachment.storagePath;
    await _removeQuietly(path);
  }

  SurgoWriteBackend _requireWriter() {
    final writer = _writer;
    if (writer == null) {
      throw RepositoryFailure.unsupported(
        'This build cannot change files.',
      );
    }
    return writer;
  }

  _PreparedUpload _prepare(String ownerProfileId, AttachmentUpload file) {
    if (ownerProfileId.trim().isEmpty) {
      throw RepositoryFailure.invalidData('Sign in before uploading a file.');
    }
    final contentType = file.contentType;
    final size = file.bytes.length;
    if (size < 1) {
      throw RepositoryFailure.invalidData('That file is empty.');
    }
    if (size > attachmentMaxBytes) {
      throw RepositoryFailure.invalidData(
        'Files must be 20 MB or smaller. That one is '
        '${(size / (1024 * 1024)).toStringAsFixed(1)} MB.',
      );
    }

    final extension = _extensionOf(file.fileName);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return _PreparedUpload(
      // `<profile id>/...` is required by the storage policy and repeated by
      // the RPC, so a tampered path cannot file bytes under another account.
      path: '$ownerProfileId/$stamp-$random.$extension',
      contentType: contentType,
    );
  }

  /// Best-effort cleanup. A failure here leaves an unreferenced object, which
  /// is better than failing an operation the database already committed.
  Future<void> _removeQuietly(String path) async {
    final storage = _storage;
    if (storage == null) return;
    try {
      await storage.removeObject(bucket: bucket, path: path);
    } catch (error) {
      debugPrint('Could not remove orphaned attachment object $path: $error');
    }
  }
}

class _PreparedUpload {
  const _PreparedUpload({required this.path, required this.contentType});

  final String path;
  final String contentType;
}

String _extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

String? _cleanLabel(String? label) {
  final trimmed = label?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.length <= 120 ? trimmed : trimmed.substring(0, 120);
}

/// The seeded demo has no real bucket, so it refuses every file action rather
/// than presenting a fake upload as a success.
class MockAttachmentRepository implements AttachmentRepository {
  const MockAttachmentRepository();

  @override
  Future<List<AttachmentRecord>> fetchAttachments(String ownerProfileId) async =>
      const [];

  @override
  Future<String> signedUrl(
    AttachmentRecord attachment, {
    Duration expiresIn = const Duration(minutes: 5),
  }) {
    throw RepositoryFailure.unsupported(
      'Files are only available for a connected account.',
    );
  }

  @override
  Future<AttachmentRecord> uploadAttachment({
    required String ownerProfileId,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  }) {
    throw RepositoryFailure.unsupported(
      'Files are only available for a connected account.',
    );
  }

  @override
  Future<AttachmentRecord> replaceAttachment({
    required AttachmentRecord attachment,
    required AttachmentUpload file,
    void Function(AttachmentUploadStage stage)? onStage,
  }) {
    throw RepositoryFailure.unsupported(
      'Files are only available for a connected account.',
    );
  }

  @override
  Future<void> deleteAttachment(AttachmentRecord attachment) {
    throw RepositoryFailure.unsupported(
      'Files are only available for a connected account.',
    );
  }
}
