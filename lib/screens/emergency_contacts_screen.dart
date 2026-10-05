import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

class EmergencyContactsScreen extends StatelessWidget {
  const EmergencyContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Emergency Contacts')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              const Text(
                'These contacts get notified automatically if you press the SOS button during a trip.',
                style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 14),
              ...state.emergencyContacts.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SbCard(
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.dangerSoft,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: const Icon(Icons.emergency_outlined, size: 18, color: Color(0xFFFFB3B3)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                                Text('${c.relation} · ${c.phone}',
                                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
                            onPressed: () => state.removeEmergencyContact(c),
                          ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 6),
              SbOutlineButton(
                label: 'Add Emergency Contact',
                icon: Icons.person_add_alt,
                onPressed: () => _showAddDialog(context, state),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext context, AppState state) {
    final nameCtrl = TextEditingController();
    final relationCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Add emergency contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full name')),
            TextField(controller: relationCtrl, decoration: const InputDecoration(labelText: 'Relation')),
            TextField(
              controller: phoneCtrl,
              decoration: const InputDecoration(labelText: 'Phone number'),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || phoneCtrl.text.trim().isEmpty) return;
              state.addEmergencyContact(EmergencyContactItem(
                id: 'ec${DateTime.now().microsecondsSinceEpoch}',
                name: nameCtrl.text.trim(),
                relation: relationCtrl.text.trim().isEmpty ? 'Contact' : relationCtrl.text.trim(),
                phone: phoneCtrl.text.trim(),
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
