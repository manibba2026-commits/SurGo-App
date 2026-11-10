import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../repositories/attachment_repository.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surgo_notice.dart';

/// The signed-in account's private files.
///
/// The bytes live in the private `attachments` bucket and every read goes
/// through a short-lived signed URL. This screen never invents a successful
/// upload: a file only appears in the list after the database recorded it.
class AttachmentsScreen extends StatefulWidget {
  const AttachmentsScreen({super.key});

  @override
  State<AttachmentsScreen> createState() => _AttachmentsScreenState();
}

class _AttachmentsScreenState extends State<AttachmentsScreen> {
  final Map<String, Future<String>> _thumbnails = {};

  List<AttachmentRecord>? _files;
  RepositoryFailure? _failure;
  bool _loading = true;
  bool _busy = false;
  String? _stage;

  AppState get state => AppState.instance;

  /// The auth uuid whose folder this screen may write to. A demo account has no
  /// such id, and must not be shown an upload button that cannot work.
  String? get _profileId =>
      state.usesHostedIdentity ? state.identity?.userId : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final profileId = _profileId;
    if (profileId == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _files = const [];
        _failure = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final files = await state.repositories.attachments
          .fetchAttachments(profileId);
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
        _thumbnails.clear();
      });
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _failure = failure;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failure = RepositoryFailure.unavailable();
        _loading = false;
      });
    }
  }

  Future<void> _pickAndUpload() async {
    final profileId = _profileId;
    if (profileId == null) {
      _notify(
        'Sign in with a connected account to upload files.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    if (_busy) return;

    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: 'Choose files',
        type: FileType.custom,
        allowedExtensions: attachmentAllowedExtensions,
      );
    } catch (_) {
      _notify(
        'The file picker could not open. Try again.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    if (picked.isEmpty) return;

    setState(() => _busy = true);
    var uploaded = 0;
    String? firstError;
    try {
      for (final file in picked) {
        try {
          await _uploadOne(profileId, file);
          uploaded++;
        } on RepositoryFailure catch (failure) {
          firstError ??= '${file.name}: ${failure.message}';
        } catch (_) {
          firstError ??= '${file.name}: that file could not be read.';
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = null;
        });
      }
    }

    await _load();
    if (!mounted) return;
    if (uploaded > 0 && firstError == null) {
      _notify(
        uploaded == 1 ? 'File uploaded.' : '$uploaded files uploaded.',
        tone: SbNoticeTone.success,
      );
    } else if (uploaded > 0) {
      _notify(
        '$uploaded uploaded. $firstError',
        tone: SbNoticeTone.warning,
      );
    } else if (firstError != null) {
      _notify(firstError, tone: SbNoticeTone.warning);
    }
  }

  Future<void> _uploadOne(String profileId, PlatformFile file) async {
    final length = await file.length();
    if (length == null || length < 1) {
      throw RepositoryFailure.invalidData('That file is empty.');
    }
    if (length > attachmentMaxBytes) {
      throw RepositoryFailure.invalidData(
        'Files must be 20 MB or smaller.',
      );
    }
    final bytes = await file.readAsBytes();
    final upload = AttachmentUpload(fileName: file.name, bytes: bytes);
    // Throws before any bytes move if the extension is not on the allowlist.
    upload.contentType;
    await state.repositories.attachments.uploadAttachment(
      ownerProfileId: profileId,
      file: upload,
      onStage: (stage) {
        if (!mounted) return;
        setState(() => _stage = _stageLabel(stage, file.name));
      },
    );
  }

  Future<void> _replace(AttachmentRecord attachment) async {
    if (_busy) return;
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Replace ${attachment.fileName}',
        type: FileType.custom,
        allowedExtensions: attachmentAllowedExtensions,
      );
    } catch (_) {
      _notify(
        'The file picker could not open. Try again.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    if (picked == null) return;

    setState(() => _busy = true);
    try {
      final length = await picked.length();
      if (length == null || length < 1) {
        throw RepositoryFailure.invalidData('That file is empty.');
      }
      if (length > attachmentMaxBytes) {
        throw RepositoryFailure.invalidData(
          'Files must be 20 MB or smaller.',
        );
      }
      final bytes = await picked.readAsBytes();
      final upload = AttachmentUpload(fileName: picked.name, bytes: bytes);
      upload.contentType;
      await state.repositories.attachments.replaceAttachment(
        attachment: attachment,
        file: upload,
        onStage: (stage) {
          if (!mounted) return;
          setState(() => _stage = _stageLabel(stage, picked!.name));
        },
      );
      await _load();
      if (!mounted) return;
      _notify('File replaced.', tone: SbNoticeTone.success);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      _notify(failure.message, tone: SbNoticeTone.warning);
    } catch (_) {
      if (!mounted) return;
      _notify(
        'That file could not be read. Choose it again.',
        tone: SbNoticeTone.warning,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = null;
        });
      }
    }
  }

  Future<void> _delete(AttachmentRecord attachment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text(
          '${attachment.fileName} will be removed from your files. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy) return;

    setState(() => _busy = true);
    try {
      await state.repositories.attachments.deleteAttachment(attachment);
      if (!mounted) return;
      setState(() {
        _files = [
          for (final file in _files ?? const <AttachmentRecord>[])
            if (file.id != attachment.id) file,
        ];
        _thumbnails.remove(attachment.id);
      });
      _notify('File deleted.', tone: SbNoticeTone.success);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      _notify(failure.message, tone: SbNoticeTone.warning);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(AttachmentRecord attachment) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final url = await state.repositories.attachments
          .signedUrl(attachment, expiresIn: const Duration(minutes: 10));
      if (!mounted) return;
      if (attachment.isImage) {
        await _showImagePreview(attachment, url);
        return;
      }
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        _notify(
          'No app could open this file type.',
          tone: SbNoticeTone.warning,
        );
      }
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      _notify(failure.message, tone: SbNoticeTone.warning);
    } catch (_) {
      if (!mounted) return;
      _notify(
        'That file could not be opened.',
        tone: SbNoticeTone.warning,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showImagePreview(AttachmentRecord attachment, String url) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppColors.panel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      attachment.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) =>
                      progress == null
                          ? child
                          : const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: AppColors.primaryLight,
                                ),
                              ),
                            ),
                  errorBuilder: (context, _, __) => const Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      'This image could not be loaded. The link may have expired.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<String> _thumbnailUrl(AttachmentRecord attachment) {
    return _thumbnails.putIfAbsent(
      attachment.id,
      () => state.repositories.attachments
          .signedUrl(attachment, expiresIn: const Duration(minutes: 5)),
    );
  }

  void _notify(String message, {SbNoticeTone tone = SbNoticeTone.info}) {
    if (!mounted) return;
    SurgoNotice.show(context, message, tone: tone);
  }

  static String _stageLabel(AttachmentUploadStage stage, String fileName) =>
      switch (stage) {
        AttachmentUploadStage.uploading => 'Uploading $fileName…',
        AttachmentUploadStage.recording => 'Saving $fileName…',
      };

  @override
  Widget build(BuildContext context) {
    final connected = _profileId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Files'),
        actions: [
          IconButton(
            tooltip: 'Upload files',
            onPressed: connected && !_busy ? _pickAndUpload : null,
            icon: const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppColors.primaryLight,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            children: [
              if (!connected)
                const SbCard(
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline,
                          size: 18, color: AppColors.muted2),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Files are available for a connected account. '
                          'Sign in to upload and keep your documents.',
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else
                _uploadCard(),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(
                  minHeight: 3,
                  color: AppColors.primaryLight,
                  backgroundColor: AppColors.panel2,
                ),
                const SizedBox(height: 6),
                Text(
                  _stage ?? 'Working…',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _body(connected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _uploadCard() {
    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Private files',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
          ),
          const SizedBox(height: 4),
          const Text(
            'Documents, spreadsheets, presentations, images, ZIP archives, '
            'audio and video. Up to 20 MB per file. Only you and staff can '
            'open them, through short-lived links.',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          SbPrimaryButton(
            label: 'Upload files',
            icon: Icons.upload_file,
            onPressed: _busy ? null : _pickAndUpload,
          ),
        ],
      ),
    );
  }

  Widget _body(bool connected) {
    if (_loading) return const SbListLoading(label: 'Loading your files…');
    final failure = _failure;
    if (failure != null) {
      return SbFailureState(failure: failure, onRetry: _load);
    }
    final files = _files ?? const <AttachmentRecord>[];
    if (files.isEmpty) {
      return SbEmptyState(
        icon: Icons.folder_open_outlined,
        message: connected
            ? 'No files yet. Upload a document to keep it here.'
            : 'Nothing to show.',
      );
    }
    return Column(
      children: [
        for (final file in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _fileCard(file),
          ),
      ],
    );
  }

  Widget _fileCard(AttachmentRecord file) {
    return SbCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: Row(
        children: [
          _leading(file),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.label ?? file.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    _categoryLabel(file.category),
                    file.sizeLabel,
                    if (file.createdAt != null) _dateLabel(file.createdAt!),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'File actions',
            enabled: !_busy,
            color: AppColors.panel2,
            icon: const Icon(Icons.more_vert,
                size: 18, color: AppColors.muted),
            onSelected: (action) {
              switch (action) {
                case 'open':
                  _open(file);
                case 'replace':
                  _replace(file);
                case 'delete':
                  _delete(file);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'open', child: Text('Open / preview')),
              PopupMenuItem(value: 'replace', child: Text('Replace')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _leading(AttachmentRecord file) {
    final icon = _iconFor(file.category);
    final tint = _tintFor(file.category);
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        color: AppColors.panel2,
        child: file.isImage
            ? FutureBuilder<String>(
                future: _thumbnailUrl(file),
                builder: (context, snapshot) {
                  final url = snapshot.data;
                  if (url == null) {
                    return Icon(icon, size: 20, color: tint);
                  }
                  return Image.network(
                    url,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (context, _, __) =>
                        Icon(icon, size: 20, color: tint),
                  );
                },
              )
            : Icon(icon, size: 20, color: tint),
      ),
    );
  }

  static IconData _iconFor(String category) => switch (category) {
        'image' => Icons.image_outlined,
        'audio' => Icons.audiotrack_outlined,
        'video' => Icons.videocam_outlined,
        'spreadsheet' => Icons.table_chart_outlined,
        'presentation' => Icons.slideshow_outlined,
        'archive' => Icons.folder_zip_outlined,
        'document' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  static Color _tintFor(String category) => switch (category) {
        'image' => AppColors.secondaryLight,
        'audio' => AppColors.primaryLight,
        'video' => AppColors.primaryLight,
        'spreadsheet' => AppColors.success,
        'presentation' => AppColors.yellow,
        'archive' => AppColors.yellow,
        _ => AppColors.muted,
      };

  static String _categoryLabel(String category) => switch (category) {
        'image' => 'Image',
        'audio' => 'Audio',
        'video' => 'Video',
        'spreadsheet' => 'Spreadsheet',
        'presentation' => 'Presentation',
        'archive' => 'Archive',
        'document' => 'Document',
        _ => 'File',
      };

  static String _dateLabel(DateTime time) {
    final local = time.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}
