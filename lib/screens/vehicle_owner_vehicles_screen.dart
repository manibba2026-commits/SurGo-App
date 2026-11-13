import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
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
import '../widgets/vehicle_photo.dart';
import 'vehicle_form_screen.dart';

/// Vehicle Owner mode — Vehicles tab. Lets the owner see their fleet
/// grouped by category (2-Wheel / 3-Wheel / 4-Wheel / Truck), add a new
/// vehicle, edit its details and take a listing off the rental catalogue.
class VehicleOwnerVehiclesScreen extends StatefulWidget {
  final bool embedded;
  const VehicleOwnerVehiclesScreen({super.key, this.embedded = true});

  @override
  State<VehicleOwnerVehiclesScreen> createState() =>
      _VehicleOwnerVehiclesScreenState();
}

class _VehicleOwnerVehiclesScreenState
    extends State<VehicleOwnerVehiclesScreen> {
  String activeFilter = 'All';
  static const filters = ['All', ...OwnedVehicle.categories];

  @override
  Widget build(BuildContext context) {
    void addVehicle() => _openForm(context);
    final content = ListView(
      padding: EdgeInsets.fromLTRB(18, widget.embedded ? 4 : 16, 18, 90),
      children: [
        if (widget.embedded)
          SbTabHeader(
            title: 'Vehicles',
            actions: [SbIconButton(icon: Icons.add, onTap: addVehicle)],
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'My Vehicles',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
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
          empty: (_) => _noVehicles(context),
          data: (context, fleet) {
            final vehicles = activeFilter == 'All'
                ? fleet
                : fleet.where((v) => v.category == activeFilter).toList();
            if (vehicles.isEmpty) return _noVehicles(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final vehicle in vehicles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _vehicleCard(context, vehicle),
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

  Widget _noVehicles(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      children: [
        const Icon(
          Icons.directions_car_outlined,
          size: 36,
          color: AppColors.muted2,
        ),
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
          onPressed: () => _openForm(context),
        ),
      ],
    ),
  );

  Widget _vehicleCard(BuildContext context, VehicleRecord v) {
    return SbTintedCard(
      tone: SbTone.vehicle,
      padding: const EdgeInsets.all(13),
      onTap: () => _showManageSheet(context, v),
      child: Row(
        children: [
          if (v.photoPaths.isNotEmpty)
            VehiclePhoto(storagePath: v.photoPaths.first, width: 46, height: 46)
          else
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: SbGradients.panel,
                borderRadius: BorderRadius.circular(SbRadius.sm),
                border: Border.all(
                  color: SbTone.vehicle.accent.withValues(alpha: 0.20),
                ),
              ),
              child: Icon(
                iconForVehicle(v.category, v.vehicleType),
                size: 22,
                color: SbTone.vehicle.accent,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${v.category} · ${v.vehicleType} · Plate ${v.plateNumber}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(
                  '${Money.format(v.pricePerDayCentavos)}/day · '
                  '⭐ ${v.rating} · ${v.totalRentals} rentals',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          SbTag(v.statusLabel, secondary: v.statusLabel == 'Listed'),
        ],
      ),
    );
  }

  void _openForm(BuildContext context, {VehicleRecord? vehicle}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VehicleFormScreen(vehicle: vehicle)),
    );
  }

  void _showManageSheet(BuildContext context, VehicleRecord v) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _VehicleManageSheet(vehicle: v, state: AppState.instance),
    );
  }
}

class _VehicleManageSheet extends StatefulWidget {
  final VehicleRecord vehicle;
  final AppState state;
  const _VehicleManageSheet({required this.vehicle, required this.state});

  @override
  State<_VehicleManageSheet> createState() => _VehicleManageSheetState();
}

class _VehicleManageSheetState extends State<_VehicleManageSheet> {
  bool _busy = false;
  String? _error;

  VehicleRecord get _vehicle => widget.vehicle;
  bool get _hosted => widget.state.usesHostedRideDispatch;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      Navigator.pop(context);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'That change could not be saved.';
      });
    }
  }

  Future<void> _confirmRemove() async {
    final confirmed = await SurgoNotice.confirm(
      context,
      title: 'Remove from listings?',
      message:
          'Renters will no longer see this vehicle. Its rental history stays '
          'intact and you can relist it at any time.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => widget.state.setOwnedVehicleListing(id: _vehicle.id, listed: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canToggle =
        _vehicle.status == 'active' || _vehicle.status == 'inactive';
    final details = [
      if (_vehicle.make != null) _vehicle.make!,
      if (_vehicle.model != null) _vehicle.model!,
      if (_vehicle.modelYear != null) '${_vehicle.modelYear}',
      if (_vehicle.color != null) _vehicle.color!,
    ].join(' · ');

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        30 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _vehicle.name,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 2),
            Text(
              'Plate ${_vehicle.plateNumber} · '
              '${Money.format(_vehicle.pricePerDayCentavos)}/day',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                details,
                style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ],
            if (_vehicle.photoPaths.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final path in _vehicle.photoPaths.take(3))
                    VehiclePhoto(storagePath: path, width: 70, height: 54),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (_hosted) ...[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _vehicle.isListed,
                onChanged: _busy || !canToggle
                    ? null
                    : (value) => _run(
                        () => widget.state.setOwnedVehicleListing(
                          id: _vehicle.id,
                          listed: value,
                        ),
                      ),
                title: Text(
                  _vehicle.isListed
                      ? 'Listed in the rental catalogue'
                      : 'Not listed',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                subtitle: Text(
                  canToggle
                      ? 'Renters can book this vehicle while it is listed.'
                      : _vehicle.status == 'suspended'
                      ? 'This vehicle is suspended by an administrator.'
                      : 'This vehicle is waiting for review.',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                  ),
                ),
                activeColor: AppColors.primary,
              ),
            ] else ...[
              const Text(
                'Set status',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.muted2,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['Listed', 'Rented', 'Maintenance']
                    .map(
                      (s) => SbChip(
                        s,
                        active: _vehicle.statusLabel == s,
                        onTap: _busy
                            ? null
                            : () {
                                widget.state.setOwnedVehicleStatusById(
                                  _vehicle.id,
                                  s,
                                );
                                Navigator.pop(context);
                              },
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 16),
            SbPrimaryButton(
              label: 'Edit details',
              icon: Icons.edit_outlined,
              onPressed: _busy
                  ? null
                  : () {
                      // Replace the sheet with the form so the back button
                      // returns to the fleet, not to a stale manage sheet.
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => VehicleFormScreen(vehicle: _vehicle),
                        ),
                      );
                    },
            ),
            const SizedBox(height: 10),
            if (_hosted) ...[
              if (_vehicle.status == 'active')
                SbOutlineButton(
                  label: 'Remove from listings',
                  icon: Icons.visibility_off_outlined,
                  onPressed: _busy ? null : _confirmRemove,
                )
              else if (_vehicle.status == 'inactive')
                SbOutlineButton(
                  label: 'Relist vehicle',
                  icon: Icons.visibility_outlined,
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => widget.state.setOwnedVehicleListing(
                            id: _vehicle.id,
                            listed: true,
                          ),
                        ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
