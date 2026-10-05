import 'package:flutter/material.dart';
import '../data/models.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
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
    final vehicles = activeFilter == 'All'
        ? MockData.rentalVehicles
        : MockData.rentalVehicles.where((v) => v.type == activeFilter).toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Row(
                children: [
                  SbIconButton(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 10),
                  const Text('Rent a Vehicle',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
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
                        style: TextStyle(color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600)),
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
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                itemCount: vehicles.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final v = vehicles[i];
                  return SbCard(
                    padding: const EdgeInsets.all(12),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => RentalDetailScreen(vehicle: v)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 84,
                          height: 66,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: const LinearGradient(
                              colors: [AppColors.panel3, AppColors.panel2],
                            ),
                          ),
                          child: Icon(v.icon, size: 30, color: AppColors.primaryLight),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(v.name,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                              const SizedBox(height: 2),
                              Text('${v.location} · ${v.availability}',
                                  style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('₱${v.pricePerDay}/day',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primaryLight,
                                          fontSize: 13)),
                                  Text('⭐ ${v.rating}',
                                      style: const TextStyle(color: AppColors.muted, fontSize: 11)),
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
            ),
          ],
        ),
      ),
    );
  }
}
