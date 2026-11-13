import 'dart:async';

import 'package:flutter/material.dart';
import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../services/geoapify_service.dart';
import '../services/location_service.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import 'common.dart';
import 'repository_states.dart';
import 'surgo_map.dart';
import 'surgo_notice.dart';

/// A location chosen in the picker, with the ids a hosted write needs.
///
/// [label] is the same "Purok 3, San Isidro" text the legacy picker returns,
/// so screens that only display the choice do not have to re-format it.
class PickedLocation {
  const PickedLocation({
    required this.barangayId,
    required this.barangayName,
    this.purokId,
    this.purokName,
  });

  final String barangayId;
  final String barangayName;
  final String? purokId;
  final String? purokName;

  String get label =>
      purokName == null ? barangayName : '$purokName, $barangayName';
}

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

/// Same sheet, but returns the barangay and purok ids as well so a hosted
/// request can store them. A hosted write cannot accept a bare label: the
/// database needs the id to enforce the service area.
Future<PickedLocation?> showHostedLocationPicker(
  BuildContext context, {
  required String title,
  String? initialBarangayName,
}) {
  return showModalBottomSheet<PickedLocation>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LocationPickerSheet(
      title: title,
      structured: true,
      initialBarangayName: initialBarangayName,
    ),
  );
}

class RideLocationChoice {
  const RideLocationChoice({
    required this.label,
    this.point,
    this.barangayId,
    this.barangayName,
    this.purokId,
    this.purokName,
  });

  final String label;
  final MapPoint? point;
  final String? barangayId;
  final String? barangayName;
  final String? purokId;
  final String? purokName;
}

/// One picker for every travel service: search real Tandag places, drop a pin
/// on the shared map, or use the device's live position. A hosted build then
/// confirms the barangay and purok so the request can be stored against the
/// service area.
Future<RideLocationChoice?> showRideLocationPicker(
  BuildContext context, {
  required String title,
  MapPoint? initialPoint,
}) async {
  final hosted = AppState.instance.usesHostedRideDispatch;
  final picked = await showModalBottomSheet<RideLocationChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _RidePlaceSearch(
      title: title,
      hosted: hosted,
      initialPoint: initialPoint,
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (!hosted) return picked;
  // The barangay comes from the hosted catalog matched against the chosen
  // label, not from a local centroid table. If it cannot be inferred the
  // confirmation sheet simply asks the user to pick one.
  final area = await showHostedLocationPicker(
    context,
    title: 'Confirm service area',
    initialBarangayName: picked.barangayName,
  );
  if (area == null) return null;
  return RideLocationChoice(
    label: picked.label.isEmpty ? area.label : '${picked.label} · ${area.label}',
    point: picked.point,
    barangayId: area.barangayId,
    barangayName: area.barangayName,
    purokId: area.purokId,
    purokName: area.purokName,
  );
}

class _RidePlaceSearch extends StatefulWidget {
  const _RidePlaceSearch({
    required this.title,
    required this.hosted,
    this.initialPoint,
  });

  final String title;
  final bool hosted;
  final MapPoint? initialPoint;

  @override
  State<_RidePlaceSearch> createState() => _RidePlaceSearchState();
}

class _RidePlaceSearchState extends State<_RidePlaceSearch> {
  final _service = GeoapifyService();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  String? _error;
  bool _loading = false;
  bool _resolvingPin = false;
  MapPoint? _pin;
  String _pinLabel = '';
  String? _pinBarangay;
  List<GeoPlace> _remote = const [];
  List<BarangayRecord> _barangays = const [];

  @override
  void initState() {
    super.initState();
    _pin = widget.initialPoint;
    if (_pin != null) {
      _pinLabel = _labelForPoint(_pin!, null);
      _pinBarangay = _barangayFromText(_pinLabel);
    }
    if (widget.hosted) unawaited(_loadBarangays());
  }

  /// Barangay names are hosted catalog rows, so the picker can only infer one
  /// after that slot has been read. It is not a local list of puroks.
  Future<void> _loadBarangays() async {
    final cache = AppState.instance.cache;
    await cache.ensure(DomainSlot.barangays);
    if (!mounted) return;
    final rows = cache.dataOf<List<BarangayRecord>>(DomainSlot.barangays);
    if (rows == null) return;
    setState(() {
      _barangays = rows;
      _pinBarangay = _barangayFromText(_pinLabel) ?? _pinBarangay;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _generation++;
    super.dispose();
  }

  void _search(String query) {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _query = query.trim();
      _error = null;
      _remote = const [];
      _loading = widget.hosted && _query.length >= 2;
    });
    if (!_loading) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final places = await _service.autocomplete(query);
        if (!mounted || generation != _generation) return;
        setState(() {
          _remote = places;
          _loading = false;
        });
      } on RepositoryFailure catch (failure) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _error = failure.message;
          _loading = false;
        });
      }
    });
  }

  Future<void> _reverse(MapPoint point) async {
    final generation = ++_generation;
    setState(() {
      _pin = point;
      _pinBarangay = null;
      _pinLabel = _labelForPoint(point, null);
      _resolvingPin = widget.hosted;
    });
    if (!widget.hosted) return;
    try {
      final place = await _service.reverseGeocode(point);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pinLabel = place == null
            ? _coordinateLabel(point)
            : _compact(place.label);
        _pinBarangay =
            _barangayFromText(place?.label ?? '') ?? _pinBarangay;
        _resolvingPin = false;
      });
    } on RepositoryFailure {
      if (!mounted || generation != _generation) return;
      setState(() => _resolvingPin = false);
    }
  }

  Future<void> _useDeviceLocation() async {
    final point = await LocationService.instance.getCurrentLocation();
    if (!mounted) return;
    if (point == null) {
      SurgoNotice.show(
        context,
        'Location permission is off. Drop a pin or search for a place instead.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    await _reverse(point);
  }

  RideLocationChoice _choice(String label, MapPoint? point, String? barangay) {
    return RideLocationChoice(
      label: label,
      point: point,
      barangayName: barangay,
    );
  }

  String _labelForPoint(MapPoint point, GeoPlace? place) {
    if (place != null) return _compact(place.label);
    return _coordinateLabel(point);
  }

  static String _coordinateLabel(MapPoint point) =>
      'Dropped pin · ${point.latitude.toStringAsFixed(4)}, '
      '${point.longitude.toStringAsFixed(4)}';

  static String _compact(String label) {
    final parts = label
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != 'Philippines')
        .take(3);
    return parts.join(' · ');
  }

  String? _barangayFromText(String text) {
    final lower = text.toLowerCase();
    if (lower.trim().isEmpty) return null;
    for (final barangay in _barangays) {
      final name = barangay.name.toLowerCase();
      final short = name
          .replaceAll(' (poblacion)', '')
          .replaceAll(' poblacion (east west)', ' poblacion')
          .trim();
      if (short.isNotEmpty && lower.contains(short)) return barangay.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Address search is Geoapify/OpenStreetMap only. Barangays and puroks are
    // chosen from the hosted catalog in the confirmation step; there is no
    // bundled landmark or purok list to fall back to.
    final remote = _remote;
    // The modal route hands down the height left after the keyboard, so the
    // sheet sizes itself from that instead of the whole screen. The map is the
    // one block that gives up height when the phone is short.
    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height * 0.9;
        final mapHeight = sheetHeight >= 520
            ? 210.0
            : sheetHeight >= 430
            ? 150.0
            : 0.0;
        return SizedBox(
          height: sheetHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  SbIconButton(
                    icon: Icons.close,
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _search,
                maxLength: 160,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search a place, barangay or landmark',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  counterText: '',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            _search('');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
              ),
            ),
            if (mapHeight > 0) const SizedBox(height: 10),
            if (mapHeight > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SurgoMap(
                    height: mapHeight,
                    borderRadius: BorderRadius.circular(16),
                  fallbackCenter: _pin ??
                      widget.initialPoint ??
                      AppState.instance.db.mapConfig.defaultCenter,
                  initialZoom: 14.5,
                  cameraPadding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                  showUserLocation: true,
                  onMapTap: _reverse,
                  onMapLongPress: _reverse,
                  markers: [
                    if (_pin != null)
                      SurgoMapMarker(
                        id: 'picked-pin',
                        position: _pin!,
                        icon: Icons.place,
                        title: 'Selected location',
                        subtitle: _pinLabel,
                        color: AppColors.yellow,
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              child: Row(
                children: [
                  Icon(
                    _pin == null ? Icons.touch_app_outlined : Icons.place,
                    size: 15,
                    color: _pin == null
                        ? AppColors.muted
                        : AppColors.yellow,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _pin == null
                          ? 'Tap the map to drop a pin, or pick a suggestion below.'
                          : _resolvingPin
                          ? 'Finding the address…'
                          : '$_pinLabel · ${_pinBarangay ?? 'Tandag City'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _useDeviceLocation,
                    icon: const Icon(Icons.my_location, size: 15),
                    label: const Text('Me'),
                  ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: Text(
                      _query.isEmpty ? 'Search or drop a pin' : 'Address results',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  if (_query.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 6, 8, 8),
                      child: Text(
                        'Type at least two characters to search OpenStreetMap '
                        'addresses, or tap the map to drop a pin.',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  for (final place in remote)
                    _PlaceTile(
                      icon: Icons.place_outlined,
                      title: place.label,
                      subtitle: 'OpenStreetMap address',
                      onTap: () => Navigator.pop(
                        context,
                        _choice(
                          _compact(place.label),
                          place.point,
                          _barangayFromText(place.label),
                        ),
                      ),
                    ),
                  if (!widget.hosted && _query.length >= 2)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'Address search needs a hosted account. Drop a pin or '
                        'use your current location instead.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ),
                  if (widget.hosted &&
                      !_loading &&
                      _query.length >= 2 &&
                      remote.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'No matching place. Drop a pin on the map instead.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
              child: SbPrimaryButton(
                label: _pin == null ? 'Drop a pin to continue' : 'Use this location',
                icon: Icons.check_rounded,
                onPressed: _pin == null
                    ? null
                    : () => Navigator.pop(
                        context,
                        _choice(_pinLabel, _pin, _pinBarangay),
                      ),
              ),
            ),
            ],
          ),
        );
      },
    );
  }

}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: AppColors.primaryLight),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: AppColors.muted),
      ),
      trailing: const Icon(Icons.chevron_right, size: 17),
      onTap: onTap,
    );
  }
}

class _LocationPickerSheet extends StatefulWidget {
  final String title;
  final bool structured;
  final String? initialBarangayName;
  const _LocationPickerSheet({
    required this.title,
    this.structured = false,
    this.initialBarangayName,
  });

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  /// The chosen barangay is held as an id, and its record is looked up in the
  /// list on every build, because a mock re-read produces new record objects
  /// for the same barangay.
  String? _barangayId;
  String? _purok;
  String? _purokId;
  String _query = '';
  bool _initialApplied = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) =>
            RepositoryView<List<BarangayRecord>>(
          slot: DomainSlot.barangays,
          empty: (_) => const SbEmptyState(
            message: 'No barangays are listed for this area yet.',
            icon: Icons.location_off_outlined,
          ),
          data: (context, all) => _body(context, scrollController, all),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ScrollController scrollController,
      List<BarangayRecord> all) {
    if (!_initialApplied) {
      _initialApplied = true;
      final hint = widget.initialBarangayName?.toLowerCase();
      if (hint != null && hint.isNotEmpty) {
        for (final barangay in all) {
          final name = barangay.name.toLowerCase();
          if (name == hint ||
              name.contains(hint) ||
              hint.contains(name.replaceAll(' (poblacion)', ''))) {
            _barangayId = barangay.id;
            break;
          }
        }
      }
    }
    final chosen = _barangayId == null
        ? const <BarangayRecord>[]
        : all.where((b) => b.id == _barangayId).toList();
    final barangay = chosen.isEmpty ? null : chosen.first;
    final filtered = _query.isEmpty
        ? all
        : all
            .where((b) => b.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

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
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 2),
          Text(
            barangay == null
                ? 'Step 1 of 2 · Choose a barangay in Tandag City'
                : 'Step 2 of 2 · Choose a purok in ${barangay.name}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (barangay == null) ...[
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
                  prefixIcon:
                      Icon(Icons.search, size: 18, color: AppColors.muted),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 13),
                    onTap: () => setState(() => _barangayId = b.id),
                    child: Row(
                      children: [
                        const Icon(Icons.location_city,
                            size: 18, color: AppColors.muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(b.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 16, color: AppColors.muted),
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
                    _barangayId = null;
                    _purok = null;
                    _purokId = null;
                  }),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(barangay.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
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
                itemCount: barangay.puroks.length,
                itemBuilder: (context, i) {
                  final p = barangay.puroks[i];
                  final selected = p.name == _purok;
                  return SbCard(
                    padding: EdgeInsets.zero,
                    borderColor: selected ? AppColors.primary : null,
                    onTap: () => setState(() {
                      _purok = p.name;
                      _purokId = p.id;
                    }),
                    child: Center(
                      child: Text(
                        p.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: selected
                              ? AppColors.primaryLight
                              : AppColors.text,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            SbPrimaryButton(
              label: _purok == null
                  ? 'Choose a purok'
                  : 'Confirm · $_purok, ${barangay.name}',
              onPressed: _purok == null
                  ? null
                  : () => Navigator.pop(
                        context,
                        widget.structured
                            ? PickedLocation(
                                barangayId: barangay.id,
                                barangayName: barangay.name,
                                purokId: _purokId,
                                purokName: _purok,
                              )
                            : '$_purok, ${barangay.name}',
                      ),
            ),
          ],
        ],
      ),
    );
  }
}
