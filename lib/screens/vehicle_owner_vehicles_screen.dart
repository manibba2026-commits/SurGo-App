import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';

/// Vehicle Owner mode — Vehicles tab. Lets the owner see their fleet
/// grouped by category (2-Wheel / 3-Wheel / 4-Wheel / Truck), add a new
/// vehicle, and manage an existing one's status.
class VehicleOwnerVehiclesScreen extends StatefulWidget {
  final bool embedded;
  const VehicleOwnerVehiclesScreen({super.key, this.embedded = true});

  @override
  State<VehicleOwnerVehiclesScreen> createState() => _VehicleOwnerVehiclesScreenState();
}

class _VehicleOwnerVehiclesScreenState extends State<VehicleOwnerVehiclesScreen> {
  String activeFilter = 'All';
  static const filters = ['All', ...OwnedVehicle.categories];

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final content = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final all = state.ownerVehicles;
        final vehicles = activeFilter == 'All' ? all : all.where((v) => v.category == activeFilter).toList();
        return ListView(
          padding: EdgeInsets.fromLTRB(18, widget.embedded ? 4 : 16, 18, 90),
          children: [
            if (widget.embedded)
              SbTabHeader(
                title: 'Vehicles',
                actions: [
                  SbIconButton(icon: Icons.add, onTap: () => _showAddVehicleSheet(context, state)),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('My Vehicles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  SbIconButton(icon: Icons.add, onTap: () => _showAddVehicleSheet(context, state)),
                ],
              ),
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => SbChip(
                  filters[i],
                  active: filters[i] == activeFilter,
                  onTap: () => setState(() => activeFilter = filters[i]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (vehicles.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Column(
                  children: [
                    const Icon(Icons.directions_car_outlined, size: 36, color: AppColors.muted2),
                    const SizedBox(height: 10),
                    Text(
                      activeFilter == 'All'
                          ? 'You haven\'t listed any vehicles yet.'
                          : 'No $activeFilter vehicles yet.',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 14),
                    SbOutlineButton(
                      label: 'Add Vehicle',
                      icon: Icons.add,
                      block: false,
                      onPressed: () => _showAddVehicleSheet(context, state),
                    ),
                  ],
                ),
              )
            else
              ...vehicles.map((v) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _vehicleCard(context, state, v),
                  )),
          ],
        );
      },
    );
    if (widget.embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(body: content);
  }

  Widget _vehicleCard(BuildContext context, AppState state, OwnedVehicle v) {
    return SbCard(
      padding: const EdgeInsets.all(13),
      onTap: () => _showManageSheet(context, state, v),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.panel3, AppColors.panel2]),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(v.icon, size: 22, color: AppColors.primaryLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 2),
                Text('${v.category} · ${v.type} · Plate ${v.plate}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                const SizedBox(height: 4),
                Text('₱${v.pricePerDay}/day · ⭐ ${v.rating} · ${v.totalRentals} rentals',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          SbTag(v.status, secondary: v.status == 'Listed'),
        ],
      ),
    );
  }

  void _showManageSheet(BuildContext context, AppState state, OwnedVehicle v) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text('Plate ${v.plate} · ₱${v.pricePerDay}/day', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(height: 16),
            const Text('Set status', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.muted2)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ['Listed', 'Rented', 'Maintenance']
                  .map((s) => SbChip(
                        s,
                        active: v.status == s,
                        onTap: () {
                          state.setOwnedVehicleStatus(v, s);
                          Navigator.pop(context);
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: 18),
            SbOutlineButton(
              label: 'Remove Vehicle',
              icon: Icons.delete_outline,
              onPressed: () {
                state.removeOwnedVehicle(v);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddVehicleSheet(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _AddVehicleForm(state: state),
      ),
    );
  }
}

class _AddVehicleForm extends StatefulWidget {
  final AppState state;
  const _AddVehicleForm({required this.state});

  @override
  State<_AddVehicleForm> createState() => _AddVehicleFormState();
}

class _AddVehicleFormState extends State<_AddVehicleForm> {
  final nameCtrl = TextEditingController();
  final plateCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  String category = OwnedVehicle.categories.first;
  late String type = OwnedVehicle.typesByCategory[category]!.first;

  @override
  void dispose() {
    nameCtrl.dispose();
    plateCtrl.dispose();
    priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final types = OwnedVehicle.typesByCategory[category]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add a vehicle', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 16),
            const Text('Category', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.muted2)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: OwnedVehicle.categories
                  .map((c) => SbChip(
                        c,
                        active: category == c,
                        onTap: () => setState(() {
                          category = c;
                          type = OwnedVehicle.typesByCategory[c]!.first;
                        }),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 14),
            const Text('Type', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.muted2)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: types
                  .map((t) => SbChip(t, active: type == t, onTap: () => setState(() => type = t)))
                  .toList(),
            ),
            const SizedBox(height: 14),
            SbEditableField(label: 'Vehicle name', controller: nameCtrl, hintText: 'e.g. Honda Click 125i'),
            const SizedBox(height: 10),
            SbEditableField(label: 'Plate number', controller: plateCtrl, hintText: 'e.g. NGD 4821'),
            const SizedBox(height: 10),
            SbEditableField(
              label: 'Price per day (₱)',
              controller: priceCtrl,
              keyboardType: TextInputType.number,
              hintText: 'e.g. 500',
            ),
            const SizedBox(height: 18),
            SbPrimaryButton(
              label: 'Add Vehicle',
              icon: Icons.check,
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty || plateCtrl.text.trim().isEmpty) return;
                final price = int.tryParse(priceCtrl.text.trim()) ?? 0;
                widget.state.addOwnedVehicle(OwnedVehicle(
                  id: 'ov${DateTime.now().microsecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  type: type,
                  category: category,
                  plate: plateCtrl.text.trim(),
                  pricePerDay: price,
                  status: 'Listed',
                  rating: 5.0,
                  totalRentals: 0,
                ));
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
