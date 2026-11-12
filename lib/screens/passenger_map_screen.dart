import 'dart:async';

import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/repository_registry.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/surgo_map.dart';

/// Passenger-side Map V1: real OpenStreetMap centered on the user's live
/// GPS, with riders and rental vehicles shown as tappable pins.
///
/// A hosted dispatch build reads online riders from the database's discovery
/// function, preserving each position's device-reported or demo provenance.
/// A seeded build keeps the fixed `mapRiders` fleet.
class PassengerMapScreen extends StatefulWidget {
  const PassengerMapScreen({super.key});

  @override
  State<PassengerMapScreen> createState() => _PassengerMapScreenState();
}

class _PassengerMapScreenState extends State<PassengerMapScreen> {
  String filter = 'All'; // All, Riders, Rentals

  Timer? _refreshTimer;
  List<RiderCandidateRecord> _candidates = const [];
  bool _loadingRiders = false;
  bool _readingRiders = false;
  int _readGeneration = 0;
  String? _riderError;
  (RepositoryRegistry, String?, String?, UserMode, bool)? _session;

  bool get _hosted => AppState.instance.usesHostedRideDispatch;
  bool get _canRead =>
      _hosted &&
      AppState.instance.isSignedIn &&
      AppState.instance.mode == UserMode.passenger;

  (RepositoryRegistry, String?, String?, UserMode, bool) get _sessionKey {
    final state = AppState.instance;
    return (
      state.repositories,
      state.identity?.userId,
      state.currentAccount?.id,
      state.mode,
      _hosted,
    );
  }

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onSessionChanged);
    _syncSession(rebuild: false);
  }

  void _onSessionChanged() => _syncSession();

  void _syncSession({bool rebuild = true}) {
    if (!mounted || _session == _sessionKey) return;
    _session = _sessionKey;
    _readGeneration++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _candidates = const [];
    _riderError = null;
    _loadingRiders = _canRead;
    if (rebuild) setState(() {});
    if (_canRead) {
      scheduleMicrotask(() => unawaited(_loadRiders()));
      // Presence changes happen on the rider's device. A short poll keeps the
      // passenger map honest without pretending a Realtime subscription is
      // available for this read.
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_loadRiders(silent: true)),
      );
    }
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onSessionChanged);
    _refreshTimer?.cancel();
    _readGeneration++;
    super.dispose();
  }

  Future<void> _loadRiders({bool silent = false}) async {
    _syncSession();
    if (!mounted || !_canRead || _readingRiders) return;
    _readingRiders = true;
    final generation = _readGeneration;
    final registry = AppState.instance.repositories;
    bool valid() =>
        mounted &&
        generation == _readGeneration &&
        _session == _sessionKey &&
        _canRead;
    if (!silent) setState(() => _loadingRiders = true);
    try {
      final candidates = await registry.rides.findAvailableRiders().timeout(
        const Duration(seconds: 20),
      );
      if (!valid()) return;
      setState(() {
        _candidates = candidates;
        _riderError = null;
        _loadingRiders = false;
      });
    } catch (error) {
      if (!valid()) return;
      setState(() {
        _riderError = error is TimeoutException
            ? 'Rider discovery timed out. Try refreshing.'
            : error is RepositoryFailure
            ? error.message
            : RepositoryFailure.unavailable(error).message;
        _loadingRiders = false;
      });
    } finally {
      _readingRiders = false;
      if (mounted) {
        _syncSession();
        if (generation != _readGeneration && _canRead) {
          unawaited(_loadRiders());
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncSession(rebuild: false);
    final db = DbService.instance;

    final riderMarkers = filter == 'Rentals'
        ? const <SurgoMapMarker>[]
        : _hosted
        ? _hostedRiderMarkers()
        : db.mapRiders.map(
            (r) => SurgoMapMarker(
              id: r.id,
              position: r.position,
              icon: surgoMarkerIcon(r.markerType),
              title: r.name,
              subtitle:
                  '${_titleCase(r.vehicleType)} · ${r.purok}, ${r.barangay}',
              faded: !r.available,
              details: [
                MapEntry('Vehicle', r.vehicleModel),
                MapEntry('Rating', '⭐ ${r.rating.toStringAsFixed(1)}'),
                MapEntry('Est. fare', Money.format(r.estimatedFare)),
                MapEntry('Status', r.available ? 'Available' : 'Offline'),
              ],
              actionLabel: r.available ? 'Book a Ride' : null,
              onAction: r.available
                  ? () => Navigator.pushNamed(context, '/booking')
                  : null,
            ),
          );

    final rentalMarkers = _hosted || filter == 'Riders'
        ? const <SurgoMapMarker>[]
        : db.mapRentalVehicles.map(
            (v) => SurgoMapMarker(
              id: v.id,
              position: v.position,
              icon: surgoMarkerIcon(v.markerType),
              title: v.name,
              subtitle:
                  '${_titleCase(v.vehicleType)} · ${v.purok}, ${v.barangay}',
              faded: !v.available,
              details: [
                MapEntry('Per day', Money.format(v.pricePerDay)),
                MapEntry('Per hour', Money.format(v.pricePerHour)),
                MapEntry('Rating', '⭐ ${v.rating.toStringAsFixed(1)}'),
                MapEntry('Status', v.available ? 'Available' : 'Rented out'),
              ],
              actionLabel: v.available ? 'View Rentals' : null,
              onAction: v.available
                  ? () => Navigator.pushNamed(context, '/rental')
                  : null,
            ),
          );

    final markers = [...riderMarkers, ...rentalMarkers];

    return Scaffold(
      body: Stack(
        children: [
          SurgoMap(
            markers: markers,
            fallbackCenter: db.mapConfig.defaultCenter,
            initialZoom: db.mapConfig.defaultZoom,
            height: MediaQuery.of(context).size.height,
            borderRadius: BorderRadius.zero,
            cameraPadding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 60,
              bottom:
                  MediaQuery.paddingOf(context).bottom + (_hosted ? 126 : 0),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(
                children: [
                  SbIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: AppColors.panel.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            _filterChip('All'),
                            _filterChip('Riders'),
                            _filterChip('Rentals'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_hosted) ...[
                    const SizedBox(width: 8),
                    SbIconButton(
                      icon: Icons.refresh,
                      onTap: () => unawaited(_loadRiders()),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_hosted)
            Positioned(
              left: 14,
              right: 14,
              bottom: 18,
              child: SafeArea(
                top: false,
                child: filter == 'Rentals'
                    ? _hostedRentalNotice()
                    : _hostedStatusPill(),
              ),
            ),
        ],
      ),
    );
  }

  List<SurgoMapMarker> _hostedRiderMarkers() {
    return [
      for (final rider in _candidates)
        if (rider.hasPosition)
          SurgoMapMarker(
            id: rider.profileId,
            position: MapPoint(rider.latitude!, rider.longitude!),
            icon: surgoMarkerIcon(
              (rider.vehicleType ?? '').toLowerCase().contains('tricycle')
                  ? 'tricycle'
                  : 'motorcycle',
            ),
            title: rider.fullName,
            subtitle:
                '${_titleCase(rider.vehicleType ?? 'Rider')} · ${rider.barangayName ?? 'Tandag City'}',
            details: [
              if (rider.vehicleLabel != null)
                MapEntry('Vehicle', rider.vehicleLabel!),
              if (rider.vehiclePlate != null)
                MapEntry('Plate', rider.vehiclePlate!),
              MapEntry('Rating', '⭐ ${rider.rating.toStringAsFixed(1)}'),
              MapEntry('Trips', '${rider.totalTrips}'),
              MapEntry(
                'Position',
                rider.isSimulated
                    ? 'Simulated demo location'
                    : 'Reported by rider device',
              ),
            ],
            actionLabel: 'Book a Ride',
            onAction: () => Navigator.pushNamed(context, '/booking'),
          ),
    ];
  }

  Widget _hostedRentalNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Rental locations are not available. Browse the catalogue instead.',
              style: TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pushNamed(context, '/rental'),
            child: const Text('View Rentals'),
          ),
        ],
      ),
    );
  }

  Widget _hostedStatusPill() {
    final count = _candidates.length;
    final positioned = _candidates.where((rider) => rider.hasPosition);
    final demo = positioned.where((rider) => rider.isSimulated).length;
    final reported = positioned.length - demo;
    final unlocated = count - positioned.length;
    final locations = [
      if (reported > 0)
        '$reported device-reported location${reported == 1 ? '' : 's'}',
      if (demo > 0) '$demo simulated demo location${demo == 1 ? '' : 's'}',
      if (unlocated > 0) '$unlocated without location',
    ].join(' · ');
    final message = _riderError != null
        ? _riderError!
        : _loadingRiders
        ? 'Refreshing riders…'
        : count == 0
        ? 'No riders online'
        : '$count rider${count == 1 ? '' : 's'} online · $locations';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _riderError == null ? AppColors.border : AppColors.danger,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _riderError == null
                ? Icons.people_outline
                : Icons.cloud_off_outlined,
            size: 16,
            color: _riderError == null ? AppColors.primary : AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label) {
    final selected = filter == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => filter = label),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.onAccent : AppColors.muted,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }
}

String _titleCase(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
