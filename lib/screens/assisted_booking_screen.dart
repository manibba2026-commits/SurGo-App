import 'package:flutter/material.dart';
import '../auth/auth_models.dart';
import '../services/tandag_places.dart';
import '../state/app_state.dart';
import 'booking_screen.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/location_picker.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

/// Covers the "Assisted Booking" feature set: booking a ride on behalf of
/// someone else (an elderly relative, a neighbor without a smartphone,
/// etc). This is a simplified simulation of call-to-book / barangay-assisted
/// booking flows — it collects the other person's details, then hands off
/// to the normal matching flow.
class AssistedBookingScreen extends StatefulWidget {
  const AssistedBookingScreen({super.key});

  @override
  State<AssistedBookingScreen> createState() => _AssistedBookingScreenState();
}

class _AssistedBookingScreenState extends State<AssistedBookingScreen> {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  String channel = 'App';
  bool _submitting = false;

  // Real Tandag landmarks instead of fictional defaults, and the shared
  // picker means these can be changed by search, dropped pin, or live GPS.
  RideLocationChoice _pickup = _place('plaza');
  RideLocationChoice _destination = _place('market');

  static RideLocationChoice _place(String id) {
    final place = TandagPlaces.byId(id);
    return RideLocationChoice(
      label: place.label,
      point: place.point,
      barangayName: place.barangay,
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool isPickup}) async {
    final state = AppState.instance;
    final registry = state.repositories;
    final userId = state.identity?.userId;
    bool current() =>
        mounted &&
        identical(registry, state.repositories) &&
        userId == state.identity?.userId;
    final picked = await showRideLocationPicker(
      context,
      title: isPickup ? 'Pickup location' : 'Destination',
      initialPoint: (isPickup ? _pickup : _destination).point,
    );
    if (!current() || picked == null) return;
    setState(() {
      if (isPickup) {
        _pickup = picked;
      } else {
        _destination = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Book for Someone')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
        children: [
          const Text(
            "Booking on behalf of a passenger who can't use the app themselves — "
            'a family member, a neighbor, or someone at a barangay-assisted booking desk.',
            style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 20),
          _sectionLabel('Requested via'),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final option in const ['App', 'Phone Call', 'SMS']) ...[
                if (option != 'App') const SizedBox(width: 8),
                Expanded(
                  child: SbChip(
                    option,
                    active: channel == option,
                    onTap: () => setState(() => channel = option),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel('Passenger details'),
          const SizedBox(height: 8),
          TextField(
            controller: nameCtrl,
            style: const TextStyle(fontSize: 13),
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Passenger name',
              prefixIcon: Icon(Icons.person_outline, size: 18),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phoneCtrl,
            keyboardType: TextInputType.phone,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Contact number',
              prefixIcon: Icon(Icons.call_outlined, size: 18),
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel('Trip details'),
          const SizedBox(height: 8),
          SbField(
            label: 'Pickup location',
            value: _pickup.label,
            leading: const Icon(
              Icons.radio_button_checked,
              size: 17,
              color: AppColors.secondary,
            ),
            onTap: () => _pick(isPickup: true),
          ),
          const SizedBox(height: 8),
          SbField(
            label: 'Destination',
            value: _destination.label,
            leading: const Icon(
              Icons.place_outlined,
              size: 17,
              color: AppColors.primary,
            ),
            onTap: () => _pick(isPickup: false),
          ),
          if (_pickup.point != null || _destination.point != null) ...[
            const SizedBox(height: 12),
            _routePreview(),
          ],
          const SizedBox(height: 14),
          const Text(
            'You will follow this request in SurGo. No SMS or trip link is sent automatically.',
            style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 22),
          SbPrimaryButton(
            label: 'Review route and fare',
            onPressed: _submitting ? null : () => _submit(state),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: const TextStyle(
      fontWeight: FontWeight.w800,
      fontSize: 12.5,
      color: AppColors.muted,
    ),
  );

  /// The same shared map used by Find a Ride, with the two chosen points and
  /// a straight-line preview — the road route and ETA are calculated on the
  /// next screen against the live routing service.
  Widget _routePreview() {
    final points = [
      if (_pickup.point != null) _pickup.point!,
      if (_destination.point != null) _destination.point!,
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(SbRadius.md),
      child: SurgoMap(
        height: 190,
        borderRadius: BorderRadius.circular(SbRadius.md),
        showUserLocation: false,
        initialZoom: 13.5,
        cameraPadding: const EdgeInsets.fromLTRB(18, 30, 18, 30),
        route: points.length == 2 ? points : const [],
        routeIsEstimate: true,
        markers: [
          if (_pickup.point != null)
            SurgoMapMarker(
              id: 'assisted-pickup',
              position: _pickup.point!,
              icon: Icons.radio_button_checked,
              title: 'Pickup',
              subtitle: _pickup.label,
              color: AppColors.secondary,
            ),
          if (_destination.point != null)
            SurgoMapMarker(
              id: 'assisted-destination',
              position: _destination.point!,
              icon: Icons.place,
              title: 'Destination',
              subtitle: _destination.label,
            ),
        ],
      ),
    );
  }

  Future<void> _submit(AppState state) async {
    if (_submitting) return;
    if (state.liveRideRequest != null) {
      Navigator.pushNamed(context, '/matching');
      return;
    }
    final phone = normalizePhoneNumber(phoneCtrl.text);
    if (nameCtrl.text.trim().isEmpty || phone == null) {
      SurgoNotice.show(
        context,
        'Enter the passenger name and a valid contact number.',
        tone: SbNoticeTone.warning,
      );
      return;
    }
    setState(() => _submitting = true);
    state.setPickup(_pickup.label, coordinates: _pickup.point);
    state.setDestination(_destination.label, coordinates: _destination.point);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookingScreen(
          forPassenger: nameCtrl.text.trim(),
          contactNumber: phone,
          requestChannel: channel,
        ),
      ),
    );
    if (mounted) setState(() => _submitting = false);
  }
}
