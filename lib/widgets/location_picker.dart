import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'common.dart';

/// Opens a bottom sheet that lets the user choose a Barangay, then a Purok
/// within it (the purok list only appears once a barangay is picked). Used
/// wherever a rider needs to specify a pickup or destination inside Tandag
/// City. Returns a formatted label like "Purok 3, San Isidro", or null if
/// the sheet was dismissed without a selection.
Future<String?> showLocationPicker(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LocationPickerSheet(title: title),
  );
}

class _LocationPickerSheet extends StatefulWidget {
  final String title;
  const _LocationPickerSheet({required this.title});

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  Barangay? _barangay;
  String? _purok;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final all = AppState.instance.barangays;
    final filtered = _query.isEmpty
        ? all
        : all.where((b) => b.name.toLowerCase().contains(_query.toLowerCase())).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.borderLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Text(widget.title,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 2),
                Text(
                  _barangay == null
                      ? 'Step 1 of 2 · Choose a barangay in Tandag City'
                      : 'Step 2 of 2 · Choose a purok in ${_barangay!.name}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                if (_barangay == null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.panel2,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Search barangay…',
                        prefixIcon: Icon(Icons.search, size: 18, color: AppColors.muted),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.separated(
                      controller: scrollController,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final b = filtered[i];
                        return SbCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          onTap: () => setState(() => _barangay = b),
                          child: Row(
                            children: [
                              const Icon(Icons.location_city, size: 18, color: AppColors.muted),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(b.name,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              ),
                              const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      SbIconButton(
                        icon: Icons.arrow_back,
                        onTap: () => setState(() {
                          _barangay = null;
                          _purok = null;
                        }),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_barangay!.name,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: GridView.builder(
                      controller: scrollController,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 2.1,
                      ),
                      itemCount: _barangay!.puroks.length,
                      itemBuilder: (context, i) {
                        final p = _barangay!.puroks[i];
                        final selected = p == _purok;
                        return SbCard(
                          padding: EdgeInsets.zero,
                          borderColor: selected ? AppColors.primary : null,
                          onTap: () => setState(() => _purok = p),
                          child: Center(
                            child: Text(
                              p,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: selected ? AppColors.primaryLight : AppColors.text,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  SbPrimaryButton(
                    label: _purok == null ? 'Choose a purok' : 'Confirm · $_purok, ${_barangay!.name}',
                    onPressed: _purok == null
                        ? null
                        : () => Navigator.pop(context, '$_purok, ${_barangay!.name}'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
