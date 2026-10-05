import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// Read-only mock list of verified rider/vehicle compliance documents:
/// driver's license, OR/CR, insurance, barangay clearance, NBI clearance.
class VehicleDocumentsScreen extends StatelessWidget {
  const VehicleDocumentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle Documents')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final docs = state.vehicleDocuments;
          return ListView(
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
              ...docs.map(
                (d) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SbCard(
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
                          child: Icon(d.iconData, size: 20, color: AppColors.secondaryLight),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
                              const SizedBox(height: 2),
                              Text('No. ${d.number}', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                              const SizedBox(height: 2),
                              Text('Expires ${d.expiry}', style: const TextStyle(color: AppColors.muted2, fontSize: 10.5)),
                            ],
                          ),
                        ),
                        SbTag(d.status, secondary: true),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
