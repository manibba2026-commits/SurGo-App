import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// The account-level verification centre: which capabilities are approved,
/// which still need documents, and the simulated review that auto-approves
/// once the documents land.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Drive the simulated review while this screen is open, so a submitted
    // application visibly moves Submitted -> Under review -> Approved without
    // the user doing anything else. Cancelled in dispose, like the existing
    // screen-owned timers in the app.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      AppState.instance.processDueVerifications();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
            children: [
              _introCard(account, state),
              const SizedBox(height: 16),
              for (final capability in CapabilityType.values) ...[
                _capabilityCard(context, state, capability),
                const SizedBox(height: 10),
              ],
              _simulatedNotice(),
            ],
          );
        },
      ),
    );
  }

  Widget _introCard(Account account, AppState state) {
    return SbCard(
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
              SbTag(state.verificationSummaryLabel, secondary: true),
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

  Widget _capabilityCard(
      BuildContext context, AppState state, CapabilityType capability) {
    final account = state.currentAccount!;
    // verificationFor also advances due simulated reviews.
    final app = state.verificationFor(capability);
    final status = app?.status ??
        (account.authorizedFor(capability)
            ? VerificationStatus.approved
            : null);

    return SbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_capabilityIcon(capability),
                  size: 18, color: AppColors.primaryLight),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
    setState(() {});
  }

  Widget _simulatedNotice() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined,
              size: 16, color: AppColors.primaryLight),
          const SizedBox(width: 9),
          const Expanded(
            child: Text(
              'Demo mode: submitted applications are auto-approved after a '
              'five-second simulated review. A real deployment would route '
              'these to SurGo staff.',
              style:
                  TextStyle(color: AppColors.muted, fontSize: 11, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

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
