import 'package:flutter/material.dart';
import '../data/db_service.dart';
import '../data/models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../services/vehicle_map_locations.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_availability.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_map.dart';
import '../widgets/vehicle_photo.dart';
import 'rental_detail_screen.dart';

class RentalListScreen extends StatefulWidget {
  const RentalListScreen({super.key});

  @override
  State<RentalListScreen> createState() => _RentalListScreenState();
}

class _RentalListScreenState extends State<RentalListScreen> {
  String activeFilter = 'All';
  String _query = '';
  static const filters = ['All', 'Motorcycle', 'Multicab', 'Van', 'Tricycle'];

  @override
  Widget build(BuildContext context) {
    // Authentication alone does not make seeded repositories hosted.
    final state = AppState.instance;
    if (state.usesHostedIdentity && state.repositories.isSupabaseBacked) {
      return RepositoryView<List<VehicleRecord>>(
        slot: DomainSlot.rentalListings,
        data: (context, records) => _buildList(
          [for (final record in records) rentalListingFromRecord(record)],
          hosted: true,
          hostedRecords: {for (final record in records) record.id: record},
        ),
        empty: (_) => _scaffold(
          const SbEmptyState(
            message: 'No vehicles are listed for rent yet.',
            icon: Icons.no_transfer_outlined,
          ),
        ),
      );
    }
    return _buildList(MockData.rentalVehicles, hosted: false);
  }

  Widget _buildList(
    List<RentalVehicle> all, {
    required bool hosted,
    Map<String, VehicleRecord> hostedRecords = const {},
  }) {
    final query = _query.trim().toLowerCase();
    final vehicles = all.where((vehicle) {
      return (activeFilter == 'All' || vehicle.type == activeFilter) &&
          (query.isEmpty ||
              '${vehicle.name} ${vehicle.type} ${vehicle.location}'
                  .toLowerCase()
                  .contains(query));
    }).toList();

    if (vehicles.isEmpty) {
      return _scaffold(
        const SbEmptyState(
          message: 'No vehicles match your search.',
          icon: Icons.search_off,
        ),
      );
    }

    // Only hosted records carry a real listing id, so pins use the same
    // deterministic pickup area the passenger map shows for that vehicle.
    final markers = <SurgoMapMarker>[];
    for (final vehicle in vehicles) {
      final record = hostedRecords[vehicle.id];
      if (record == null) continue;
      final location = approximateVehicleLocation(
        record.id,
        center: DbService.instance.mapConfig.defaultCenter,
        serviceAreaName: record.serviceAreaName,
      );
      markers.add(
        SurgoMapMarker(
          id: 'rental-${record.id}',
          position: location.point,
          icon: surgoMarkerIcon(record.vehicleType.toLowerCase()),
          title: vehicle.name,
          subtitle: '${vehicle.type} · ${location.barangay}',
          details: [
            MapEntry('Per day', Money.format(vehicle.pricePerDay)),
            MapEntry('Rating', '⭐ ${vehicle.rating}'),
            MapEntry('Owner', record.ownerName ?? 'Vehicle owner'),
            MapEntry('Pickup', location.label),
          ],
          actionLabel: 'View vehicle',
          onAction: () => _openDetail(context, vehicle),
        ),
      );
    }

    return _scaffold(
      ListView.separated(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        itemCount: vehicles.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final v = vehicles[i];
          // Read the listing's real state rather than the seed's free-text
          // note, so this card and the detail screen's date check are
          // answering the same question from the same data. A hosted listing
          // is an active vehicle; the server refuses any overlapping dates.
          final listing = hosted
              ? (v.availability == 'Available today'
                    ? RentalListingState.available
                    : RentalListingState.unknown)
              : AppState.instance.rentalListingState(v.id);
          final record = hostedRecords[v.id];
          final photoPath = record != null && record.photoPaths.isNotEmpty
              ? record.photoPaths.first
              : null;
          return SbTintedCard(
            tone: SbTone.rent,
            padding: const EdgeInsets.all(12),
            onTap: () => _openDetail(context, v),
            child: Row(
              children: [
                if (photoPath != null)
                  VehiclePhoto(
                    storagePath: photoPath,
                    width: 84,
                    height: 66,
                    borderRadius: BorderRadius.circular(SbRadius.sm - 2),
                  )
                else
                  Container(
                    width: 84,
                    height: 66,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(SbRadius.sm - 2),
                      gradient: SbGradients.panel,
                    ),
                    child: Icon(v.icon, size: 30, color: SbTone.rent.accent),
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
                        v.location,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          SbTag(
                            listing.label,
                            accent: _tagAccent(listing),
                            tint: _tagTint(listing),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              listing.isBookable ? v.type : 'Dates unavailable',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: listing.isBookable
                                    ? AppColors.muted
                                    : AppColors.danger,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${Money.format(v.pricePerDay)}/day',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.primaryLight,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            '⭐ ${v.rating}',
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
      markers: markers,
    );
  }

  void _openDetail(BuildContext context, RentalVehicle vehicle) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RentalDetailScreen(vehicle: vehicle)),
    );
  }

  Widget _scaffold(Widget body, {List<SurgoMapMarker> markers = const []}) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Row(
                children: [
                  SbIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Rent a Vehicle',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ],
              ),
            ),
            if (markers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: Stack(
                  children: [
                    SurgoMap(
                      markers: markers,
                      showUserLocation: false,
                      initialZoom: 13.5,
                      height: 176,
                      borderRadius: BorderRadius.circular(SbRadius.md),
                      cameraPadding: const EdgeInsets.fromLTRB(14, 38, 14, 34),
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.panel.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            '${markers.length} vehicle'
                            '${markers.length == 1 ? '' : 's'} on the map · '
                            'tap a pin',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Search vehicles, brands…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: SizedBox(
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
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  /// Text colour for the listing's status pill.
  ///
  /// Green for bookable, amber while it is out, red when no dates will work:
  /// the pill should be readable at a glance without opening the vehicle.
  static Color? _tagAccent(RentalListingState state) => switch (state) {
    RentalListingState.available => AppColors.success,
    RentalListingState.rented => AppColors.yellow,
    RentalListingState.maintenance => AppColors.danger,
    RentalListingState.unknown => AppColors.muted,
  };

  /// Translucent fill matching [_tagAccent].
  static Color _tagTint(RentalListingState state) => switch (state) {
    RentalListingState.available => AppColors.successSoft,
    RentalListingState.rented => AppColors.yellowSoft,
    RentalListingState.maintenance => AppColors.dangerSoft,
    RentalListingState.unknown => AppColors.panel3,
  };
}
