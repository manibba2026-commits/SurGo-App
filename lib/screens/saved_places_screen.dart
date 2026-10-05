import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class SavedPlacesScreen extends StatelessWidget {
  const SavedPlacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved Places')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              ...state.savedPlaces.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SbCard(
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.panel2,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(p.iconData, size: 18, color: AppColors.primaryLight),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(p.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                const SizedBox(height: 2),
                                Text(p.address, style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
                            onPressed: () => state.removeSavedPlace(p),
                          ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 6),
              SbOutlineButton(
                label: 'Add a Place',
                icon: Icons.add_location_alt_outlined,
                onPressed: () => _showAddDialog(context, state),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext context, AppState state) {
    final labelCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Add a saved place'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(labelText: 'Label (e.g. Gym)'),
            ),
            TextField(
              controller: addressCtrl,
              decoration: const InputDecoration(labelText: 'Address'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (labelCtrl.text.trim().isEmpty || addressCtrl.text.trim().isEmpty) return;
              state.addSavedPlace(SavedPlace(
                id: 'sp${DateTime.now().microsecondsSinceEpoch}',
                label: labelCtrl.text.trim(),
                address: addressCtrl.text.trim(),
                icon: 'place',
              ));
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
