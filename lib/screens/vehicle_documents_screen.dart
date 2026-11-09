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
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.secondarySoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.verified_user, color: AppColors.secondaryLight, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'All documents are verified and up to date.',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          RepositoryView<List<VehicleDocumentRecord>>(
            slot: DomainSlot.ownerVehicleDocuments,
            empty: (_) => const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'No documents on file yet.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
            data: (context, documents) => Column(
              children: [
                for (final document in documents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _card(document),
                  ),
              ],
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
