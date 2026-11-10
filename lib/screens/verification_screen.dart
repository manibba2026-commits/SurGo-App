import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../data/verification_policy.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/verification_repository.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';

/// The account-level verification centre: which capabilities are approved,
/// which still need documents, and the state of the review.
///
/// A Supabase account submits to the real pipeline and waits for an admin
/// decision. The offline demo keeps its own simulated review, which is the only
/// place an application is approved without a person deciding.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  Timer? _ticker;

  /// Files picked in this screen but not submitted yet, per capability and
  /// document. Held here rather than in the store because an unsubmitted
  /// document must not exist anywhere the backend could see it.
  final Map<CapabilityType, Map<String, VerificationUpload>> _picked = {};
  bool _busy = false;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    if (state.usesHostedIdentity) {
      // The real queue is read once on open; "Check again" re-reads it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) state.ensureHostedVerification();
      });
    } else {
      // Drive the simulated review while this screen is open, so a submitted
      // demo application visibly moves Submitted -> Under review -> Approved
      // without the user doing anything else.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        state.processDueVerifications();
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verification')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final account = state.currentAccount;
          if (account == null) {
            return const Center(
              child: Text('Sign in to manage verification.',
                  style: TextStyle(color: AppColors.muted)),
            );
          }
          final hosted = state.usesHostedIdentity;
          final list = ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _introCard(account),
              const SizedBox(height: 16),
              if (hosted) ...[
                _hostedNotice(),
                const SizedBox(height: 12),
              ],
              for (final capability in CapabilityType.values) ...[
                _capabilityCard(context, account, capability, hosted),
                const SizedBox(height: 10),
              ],
              if (!hosted) _simulatedNotice(),
            ],
          );
          // Pull-to-refresh is what brings an admin decision onto this screen.
          return hosted
              ? RefreshIndicator(
                  onRefresh: () => _refresh(showNotice: true),
                  child: list,
                )
              : list;
        },
      ),
    );
  }

  Future<void> _refresh({bool showNotice = false}) async {
    await state.refreshHostedVerification();
    if (!mounted) return;
    if (showNotice) {
      SurgoNotice.show(
        context,
        state.hostedVerificationLoaded
            ? 'Verification status refreshed.'
            : 'Could not refresh verification. Check your connection.',
        tone: state.hostedVerificationLoaded
            ? SbNoticeTone.success
            : SbNoticeTone.warning,
      );
    }
    setState(() {});
  }

  Widget _introCard(Account account) {
    return SbTintedCard(
      tone: SbTone.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  size: 18, color: AppColors.primaryLight),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Account verification',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              ),
              SbTag(
                state.usesHostedIdentity
                    ? _hostedSummaryLabel()
                    : state.verificationSummaryLabel,
                secondary: true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Verification is per account and unlocks every mode: prove you '
            'can drive, earn or rent once and those capabilities appear here '
            'as approved.',
            style:
                TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _capabilityCard(BuildContext context, Account account,
      CapabilityType capability, bool hosted) {
    if (hosted) return _hostedCapabilityCard(account, capability);
    // verificationFor also advances due simulated reviews.
    final app = state.verificationFor(capability);
    final status = app?.status ??
        (account.authorizedFor(capability)
            ? VerificationStatus.approved
            : null);

    return SbTintedCard(
      tone: _toneFor(status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbToneIcon(
                tone: _toneFor(status),
                icon: _capabilityIcon(capability),
                size: 34,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(capability.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(_statusLabel(status), secondary: status != null),
            ],
          ),
          const SizedBox(height: 4),
          ..._capabilityBody(context, state, account, capability, app, status),
        ],
      ),
    );
  }

  // ---- hosted (Supabase-backed) verification ----

  String _hostedSummaryLabel() {
    if (!state.hostedVerificationLoaded) return 'Loading';
    final apps = state.hostedVerificationApplications;
    if (apps.any((a) => a.status == 'needs_resubmission')) return 'Action needed';
    if (apps.any((a) => a.status == 'submitted' || a.status == 'under_review')) {
      return 'In review';
    }
    final pending = [CapabilityType.rider, CapabilityType.vehicleOwner]
        .where((c) => !state.authorizedFor(c))
        .length;
    return pending == 0 ? 'Fully verified' : '$pending to go';
  }

  /// The newest real application for [capability], or null when this account
  /// has never submitted one. History rows are filtered out: a rejected
  /// application from last month must not hide a newer submission.
  VerificationApplicationRecord? _hostedApplicationFor(
      CapabilityType capability) {
    final token = verificationCapabilityToken(capability);
    for (final application in state.hostedVerificationApplications) {
      if (application.capabilityType != token) continue;
      if (application.status == 'approved' ||
          application.status == 'rejected') {
        continue;
      }
      return application;
    }
    return null;
  }

  Widget _hostedCapabilityCard(Account account, CapabilityType capability) {
    final approved = account.authorizedFor(capability);
    final application = _hostedApplicationFor(capability);
    final status = approved ? 'approved' : application?.status;
    return SbTintedCard(
      tone: _hostedTone(status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SbToneIcon(
                tone: _hostedTone(status),
                icon: _capabilityIcon(capability),
                size: 34,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(capability.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              SbTag(_hostedStatusLabel(status), secondary: status != null),
            ],
          ),
          const SizedBox(height: 6),
          ..._hostedCapabilityBody(capability, approved, application, status),
        ],
      ),
    );
  }

  List<Widget> _hostedCapabilityBody(
    CapabilityType capability,
    bool approved,
    VerificationApplicationRecord? application,
    String? status,
  ) {
    if (capability == CapabilityType.passenger) {
      return const [
        Text('Always available. No documents needed.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
      ];
    }

    if (approved) {
      return const [
        Text('Approved — this capability is unlocked for your account.',
            style: TextStyle(color: AppColors.success, fontSize: 11.5)),
      ];
    }

    if (status == 'submitted' || status == 'under_review') {
      return [
        Text(
          application?.submittedAt == null
              ? 'Submitted. A SurGo reviewer will check your documents.'
              : 'Submitted ${_dateLabel(application!.submittedAt!)}. '
                  'A SurGo reviewer will check your documents.',
          style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
        ),
        const SizedBox(height: 6),
        const Text(
          'You will see the decision here. Approving grants the role; a '
          'rejection or resubmission request shows the reviewer\'s reason.',
          style: TextStyle(
              color: AppColors.muted2, fontSize: 10.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        SbOutlineButton(
          label: 'Check again',
          block: false,
          onPressed: _busy ? null : () => _refresh(showNotice: true),
        ),
      ];
    }

    final rejected = status == 'needs_resubmission' || status == 'rejected';
    final specs = VerificationPolicy.requirementsFor(capability);
    final picked = _picked[capability] ?? const <String, VerificationUpload>{};
    final complete = specs.every((spec) => picked[spec.id] != null);
    return [
      if (rejected) ...[
        Text(
          application?.rejectionReason ??
              'A reviewer asked for different documents.',
          style: const TextStyle(
              color: AppColors.danger, fontSize: 11.5, height: 1.4),
        ),
        const SizedBox(height: 10),
      ] else ...[
        const Text(
          'Choose every document below and submit. A SurGo admin reviews '
          'them; nothing is approved automatically.',
          style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 10),
      ],
      for (var i = 0; i < specs.length; i++) ...[
        _hostedDocumentRow(capability, specs[i], picked[specs[i].id]),
        if (i != specs.length - 1)
          const Divider(height: 16, color: AppColors.border),
      ],
      const SizedBox(height: 6),
      Text(
        '${specs.where((spec) => picked[spec.id] != null).length} of '
        '${specs.length} chosen',
        style: const TextStyle(
            color: AppColors.muted2,
            fontSize: 11,
            fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      SbPrimaryButton(
        label: _busy
            ? 'Submitting…'
            : rejected
                ? 'Resubmit for review'
                : 'Submit for review',
        icon: Icons.send_rounded,
        onPressed: complete && !_busy
            ? () => _submitHosted(capability, specs)
            : null,
      ),
    ];
  }

  Widget _hostedDocumentRow(
      CapabilityType capability, VerificationDocSpec spec, VerificationUpload? picked) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          picked != null
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked,
          size: 17,
          color: picked != null ? AppColors.success : AppColors.muted2,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(spec.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 12)),
              const SizedBox(height: 1),
              Text(
                picked?.fileName ?? spec.hint,
                style: TextStyle(
                    color: picked != null ? AppColors.success : AppColors.muted,
                    fontSize: 10.5,
                    height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _busy ? null : () => _pickDocument(capability, spec),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primaryLight,
            textStyle:
                const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
          ),
          child: Text(picked == null ? 'Choose' : 'Replace'),
        ),
      ],
    );
  }

  Future<void> _pickDocument(
      CapabilityType capability, VerificationDocSpec spec) async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: spec.label,
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      );
      if (file == null) return;
      final size = await file.length();
      if (size != null && size > 10 * 1024 * 1024) {
        if (!mounted) return;
        SurgoNotice.show(
          context,
          'Files must be 10 MB or smaller.',
          tone: SbNoticeTone.warning,
        );
        return;
      }
      final bytes = await file.readAsBytes();
      final upload = VerificationUpload(
        documentType: spec.id,
        label: spec.label,
        fileName: file.name,
        bytes: bytes,
      );
      // Throws for an extension the bucket will not accept.
      upload.contentType;
      if (!mounted) return;
      setState(() {
        (_picked[capability] ??= {})[spec.id] = upload;
      });
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
      );
    } catch (_) {
      if (!mounted) return;
      SurgoNotice.show(
        context,
        'That file could not be read. Choose it again.',
        tone: SbNoticeTone.warning,
      );
    }
  }

  Future<void> _submitHosted(
      CapabilityType capability, List<VerificationDocSpec> specs) async {
    final picked = _picked[capability] ?? const <String, VerificationUpload>{};
    final uploads = [
      for (final spec in specs)
        if (picked[spec.id] != null) picked[spec.id]!,
    ];
    if (uploads.length != specs.length) return;

    setState(() => _busy = true);
    final result = await state.submitHostedVerification(
      capability: capability,
      documents: uploads,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _picked.remove(capability);
    });
    SurgoNotice.show(
      context,
      result.ok
          ? 'Submitted. A SurGo reviewer will check your documents.'
          : result.error ?? 'Verification could not be submitted.',
      tone: result.ok ? SbNoticeTone.success : SbNoticeTone.warning,
    );
  }

  Widget _hostedNotice() {
    return const SbStatusBanner(
      tone: SbTone.info,
      icon: Icons.verified_outlined,
      title: 'Reviewed by SurGo staff',
      message:
          'Applications go to the admin dashboard. Your documents stay '
          'private; only you and the reviewers can open them. Nothing is '
          'approved automatically.',
    );
  }

  static String _dateLabel(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static SbTone _hostedTone(String? status) => switch (status) {
        'approved' => SbTone.success,
        'needs_resubmission' => SbTone.warning,
        'rejected' => SbTone.danger,
        'submitted' || 'under_review' => SbTone.info,
        null => SbTone.neutral,
        _ => SbTone.brand,
      };

  static String _hostedStatusLabel(String? status) => switch (status) {
        null => 'Eligible',
        'approved' => 'Approved',
        'submitted' => 'Submitted',
        'under_review' => 'Under review',
        'draft' => 'In progress',
        'rejected' => 'Rejected',
        'needs_resubmission' => 'Action needed',
        _ => status,
      };

  List<Widget> _capabilityBody(
    BuildContext context,
    AppState state,
    Account account,
    CapabilityType capability,
    VerificationApplication? app,
    VerificationStatus? status,
  ) {
    if (capability == CapabilityType.passenger) {
      return const [
        Text('Always available. No documents needed.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
      ];
    }

    if (status == VerificationStatus.approved && app == null) {
      return const [
        Text('Active — this capability is unlocked for your account.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
      ];
    }

    if (app == null) {
      return [
        const Text(
          'Apply with a short checklist and the demo auto-approves once it '
          'is complete.',
          style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 10),
        SbOutlineButton(
          label: 'Start verification',
          block: false,
          onPressed: () {
            state.startVerification(capability);
            setState(() {});
          },
        ),
      ];
    }

    switch (app.status) {
      case VerificationStatus.draft:
        return [
          const Text('Tap each item to upload (demo).',
              style: TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 6),
          for (var i = 0; i < app.documents.length; i++) ...[
            _documentRow(context, state, app, app.documents[i]),
            if (i != app.documents.length - 1)
              const Divider(height: 16, color: AppColors.border),
          ],
          const SizedBox(height: 8),
          Text(
            '${app.documents.where((d) => d.uploaded).length} of '
            '${app.documents.length} uploaded',
            style: const TextStyle(
                color: AppColors.muted2,
                fontSize: 11,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          app.canSubmit
              ? SbPrimaryButton(
                  label: 'Submit for review',
                  icon: Icons.send_rounded,
                  onPressed: () => _submit(context, state, app),
                )
              : SbOutlineButton(
                  label: 'Upload all documents to submit',
                  block: false,
                  onPressed: () => _submit(context, state, app),
                ),
        ];
      case VerificationStatus.submitted:
      case VerificationStatus.underReview:
        return [
          const SizedBox(height: 2),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Submitted — the demo auto-approves in a few seconds.',
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ];
      case VerificationStatus.approved:
        return [
          const Text('Approved. This capability is unlocked for your account.',
              style: TextStyle(color: AppColors.success, fontSize: 11.5)),
        ];
      case VerificationStatus.rejected:
      case VerificationStatus.needsResubmission:
        return [
          Text(
            app.reviewerNote ?? 'Review needed before resubmission.',
            style: const TextStyle(
                color: AppColors.danger, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          SbOutlineButton(
            label: 'Review and resubmit',
            block: false,
            onPressed: () {
              state.startVerification(capability);
              setState(() {});
            },
          ),
        ];
    }
  }

  Widget _documentRow(BuildContext context, AppState state,
      VerificationApplication app, VerificationDocumentItem doc) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (state.markDocumentUploaded(app.id, doc.id)) setState(() {});
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              doc.uploaded
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 17,
              color: doc.uploaded ? AppColors.success : AppColors.muted2,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(doc.label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12)),
                  const SizedBox(height: 1),
                  Text(doc.hint,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 10.5, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit(
      BuildContext context, AppState state, VerificationApplication app) {
    final result = state.submitVerification(app.id);
    SurgoNotice.show(
      context,
      result.message,
      tone: result == VerificationSubmitResult.ok
          ? SbNoticeTone.success
          : SbNoticeTone.warning,
    );
    setState(() {});
  }

  Widget _simulatedNotice() {
    return const SbStatusBanner(
      tone: SbTone.info,
      icon: Icons.science_outlined,
      title: 'Demo verification',
      message:
          'Submitted applications are auto-approved after a five-second '
          'simulated review. A real deployment would route these to SurGo '
          'staff.',
    );
  }

  static SbTone _toneFor(VerificationStatus? status) => switch (status) {
        VerificationStatus.approved => SbTone.success,
        VerificationStatus.needsResubmission => SbTone.warning,
        VerificationStatus.rejected => SbTone.danger,
        VerificationStatus.submitted ||
        VerificationStatus.underReview =>
          SbTone.info,
        VerificationStatus.draft => SbTone.brand,
        null => SbTone.neutral,
      };

  IconData _capabilityIcon(CapabilityType capability) {
    switch (capability) {
      case CapabilityType.passenger:
        return Icons.person_outline;
      case CapabilityType.earner:
        return Icons.run_circle_outlined;
      case CapabilityType.rider:
        return Icons.electric_rickshaw;
      case CapabilityType.vehicleOwner:
        return Icons.directions_car_filled_outlined;
    }
  }

  String _statusLabel(VerificationStatus? status) {
    switch (status) {
      case null:
        return 'Eligible';
      case VerificationStatus.approved:
        return 'Approved';
      case VerificationStatus.submitted:
        return 'Submitted';
      case VerificationStatus.underReview:
        return 'Under review';
      case VerificationStatus.draft:
        return 'In progress';
      case VerificationStatus.rejected:
        return 'Rejected';
      case VerificationStatus.needsResubmission:
        return 'Action needed';
    }
  }
}
