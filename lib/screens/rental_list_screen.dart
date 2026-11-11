import 'package:flutter/material.dart';
import '../data/models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_mappers.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../state/rental_availability.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/repository_states.dart';
import '../widgets/surfaces.dart';
import 'rental_detail_screen.dart';

class RentalListScreen extends StatefulWidget {
  const RentalListScreen({super.key});

  @override
  State<RentalListScreen> createState() => _RentalListScreenState();
}

class _RentalListScreenState extends State<RentalListScreen> {
  String activeFilter = 'All';
  static const filters = ['All', 'Motorcycle', 'Multicab', 'Van', 'Tricycle'];

  @override
  Widget build(BuildContext context) {
    // A hosted build lists the vehicles the database says are active; a mock
    // build keeps the seeded catalogue it has always shown.
    if (AppState.instance.usesHostedIdentity) {
      return RepositoryView<List<VehicleRecord>>(
        slot: DomainSlot.rentalListings,
        data: (context, records) => _buildList(
          [for (final record in records) rentalListingFromRecord(record)],
          hosted: true,
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

  Widget _buildList(List<RentalVehicle> all, {required bool hosted}) {
    final vehicles = activeFilter == 'All'
        ? all
        : all.where((v) => v.type == activeFilter).toList();

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
          return SbTintedCard(
            tone: SbTone.rent,
            padding: const EdgeInsets.all(12),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => RentalDetailScreen(vehicle: v)),
            ),
            child: Row(
              children: [
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
                      Text(v.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(v.location,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 11)),
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
                          Text('${Money.format(v.pricePerDay)}/day',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primaryLight,
                                  fontSize: 13)),
                          Text('⭐ ${v.rating}',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 11)),
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
    );
  }

  Widget _scaffold(Widget body) {
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
                      onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 10),
                  const Text('Rent a Vehicle',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search, size: 18, color: AppColors.muted),
                    SizedBox(width: 10),
                    Text('Search vehicles, brands…',
                        style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
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
