import 'package:flutter/material.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';

/// Read-only compliance documents for the vehicles this account owns: driver's
/// licence, OR/CR, insurance, barangay and NBI clearance.
///
/// The list is a repository read because every column the card shows is on the
/// row: the type label, the number, the review status and a real expiry date.
class VehicleDocumentsScreen extends StatelessWidget {
  const VehicleDocumentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle Documents')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
        children: [
          RepositoryView<List<VehicleDocumentRecord>>(
            slot: DomainSlot.ownerVehicleDocuments,
            empty: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _banner(
                  'No documents are on file for this fleet yet.',
                  verified: false,
                ),
                const SizedBox(height: 18),
                const Text(
                  'No documents on file yet.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
            data: (context, documents) {
              // The banner states what the rows actually say; a single pending
              // or expired paper must not be summarised as "all verified".
              final allVerified =
                  documents.every((d) => d.status == 'approved');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _banner(
                    allVerified
                        ? 'All documents are verified and up to date.'
                        : 'Some documents still need review or have expired.',
                    verified: allVerified,
                  ),
                  const SizedBox(height: 18),
                  for (final document in documents)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _card(document),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _banner(String message, {required bool verified}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: verified ? AppColors.secondarySoft : AppColors.panel2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: (verified ? AppColors.secondary : AppColors.border)
                .withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            verified ? Icons.verified_user : Icons.info_outline,
            color: verified ? AppColors.secondaryLight : AppColors.muted,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(VehicleDocumentRecord d) {
    return SbCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.panel2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(iconForVehicleDocument(d.documentType),
                size: 20, color: AppColors.secondaryLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.documentType,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text('No. ${d.documentNumber ?? '—'}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                const SizedBox(height: 2),
                Text('Expires ${displayDateOnly(d.expiresAt)}',
                    style: const TextStyle(color: AppColors.muted2, fontSize: 10.5)),
              ],
            ),
          ),
          SbTag(documentStatusLabel(d.status), secondary: true),
        ],
      ),
    );
  }
}
