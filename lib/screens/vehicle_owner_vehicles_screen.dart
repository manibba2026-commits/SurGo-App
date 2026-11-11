import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_shell.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_notice.dart';

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
    // The add/status/remove actions only rewrite the seeded store, so a hosted
    // fleet could show a change the database never saw. A live account gets a
    // plain notice instead of a fake success.
    final hosted = state.usesHostedIdentity;
    void addVehicle() => hosted
        ? _notListedYet(context)
        : _showAddVehicleSheet(context, state);
    final content = ListView(
      padding: EdgeInsets.fromLTRB(18, widget.embedded ? 4 : 16, 18, 90),
      children: [
        if (widget.embedded)
          SbTabHeader(
            title: 'Vehicles',
            actions: [
              SbIconButton(icon: Icons.add, onTap: addVehicle),
            ],
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('My Vehicles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              SbIconButton(icon: Icons.add, onTap: addVehicle),
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
        RepositoryView<List<VehicleRecord>>(
          slot: DomainSlot.ownerFleet,
          empty: (_) => _noVehicles(context, state),
          data: (context, fleet) {
            final vehicles = activeFilter == 'All'
                ? fleet
                : fleet.where((v) => v.category == activeFilter).toList();
            if (vehicles.isEmpty) return _noVehicles(context, state);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final vehicle in vehicles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _vehicleCard(context, state, vehicle),
                  ),
              ],
            );
          },
        ),
      ],
    );
    if (widget.embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(body: content);
  }

  Widget _noVehicles(BuildContext context, AppState state) => Padding(
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
              onPressed: state.usesHostedIdentity
                  ? () => _notListedYet(context)
                  : () => _showAddVehicleSheet(context, state),
            ),
          ],
        ),
      );

  Widget _vehicleCard(BuildContext context, AppState state, VehicleRecord v) {
    return SbTintedCard(
      tone: SbTone.vehicle,
      padding: const EdgeInsets.all(13),
      onTap: () => _showManageSheet(context, state, v),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: SbGradients.panel,
              borderRadius: BorderRadius.circular(SbRadius.sm),
              border: Border.all(
                  color: SbTone.vehicle.accent.withValues(alpha: 0.20)),
            ),
            child: Icon(iconForVehicle(v.category, v.vehicleType),
                size: 22, color: SbTone.vehicle.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 2),
                Text('${v.category} · ${v.vehicleType} · Plate ${v.plateNumber}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                const SizedBox(height: 4),
                Text('${Money.format(v.pricePerDayCentavos)}/day · ⭐ ${v.rating} · ${v.totalRentals} rentals',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
          SbTag(v.statusLabel, secondary: v.statusLabel == 'Listed'),
        ],
      ),
    );
  }

  void _showManageSheet(BuildContext context, AppState state, VehicleRecord v) {
    final hosted = state.usesHostedIdentity;
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
            Text('Plate ${v.plateNumber} · ${Money.format(v.pricePerDayCentavos)}/day', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(height: 16),
            if (hosted)
              const Text(
                'Listing changes aren\'t available for live accounts yet. '
                'This vehicle\'s status is set by the rentals the database records.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              )
            else ...[
              const Text('Set status', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.muted2)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['Listed', 'Rented', 'Maintenance']
                    .map((s) => SbChip(
                          s,
                          active: v.statusLabel == s,
                          onTap: () {
                            state.setOwnedVehicleStatusById(v.id, s);
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
                  state.removeOwnedVehicleById(v.id);
                  Navigator.pop(context);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _notListedYet(BuildContext context) {
    SurgoNotice.show(
      context,
      'Adding vehicles from the app isn\'t enabled for live accounts yet.',
      tone: SbNoticeTone.info,
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
                // The field is labelled in pesos, so convert on the way in rather
                // than storing the typed number as if it were centavos.
                final price = Money.tryParsePesos(priceCtrl.text) ?? 0;
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
