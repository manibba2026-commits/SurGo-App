import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

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
  final pickupCtrl = TextEditingController(text: 'Barangay Hall, Poblacion');
  final destinationCtrl =
      TextEditingController(text: 'Tandag City Public Market');
  String channel = 'App';

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    pickupCtrl.dispose();
    destinationCtrl.dispose();
    super.dispose();
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
          const SizedBox(height: 18),
          const Text('Requested via',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.muted)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: SbChip('App',
                      active: channel == 'App',
                      onTap: () => setState(() => channel = 'App'))),
              const SizedBox(width: 8),
              Expanded(
                  child: SbChip('Phone Call',
                      active: channel == 'Phone Call',
                      onTap: () => setState(() => channel = 'Phone Call'))),
              const SizedBox(width: 8),
              Expanded(
                  child: SbChip('SMS',
                      active: channel == 'SMS',
                      onTap: () => setState(() => channel = 'SMS'))),
            ],
          ),
          const SizedBox(height: 18),
          const Text('Passenger details',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.muted)),
          const SizedBox(height: 8),
          _textField('Passenger name', nameCtrl, Icons.person_outline),
          const SizedBox(height: 8),
          _textField('Contact number', phoneCtrl, Icons.call_outlined,
              keyboardType: TextInputType.phone),
          const SizedBox(height: 18),
          const Text('Trip details',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.muted)),
          const SizedBox(height: 8),
          _textField('Pickup location', pickupCtrl, Icons.radio_button_checked),
          const SizedBox(height: 8),
          _textField('Destination', destinationCtrl, Icons.place_outlined),
          const SizedBox(height: 24),
          SbPrimaryButton(
            label: 'Find a Rider for Them',
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty ||
                  phoneCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text(
                          'Enter the passenger\'s name and contact number first')),
                );
                return;
              }
              state.setPickup(pickupCtrl.text.trim());
              state.setDestination(destinationCtrl.text.trim());
              // Create the request before matching, exactly like the normal
              // booking screen: without it the matching screen has nothing to
              // match against and dead-ends on "No active request". The
              // assisted passenger's name rides on the request so the rider
              // sees who is actually travelling.
              state.createRideRequest(forPassenger: nameCtrl.text.trim());
              Navigator.pushNamed(context, '/matching');
            },
          ),
        ],
      ),
    );
  }

  Widget _textField(String label, TextEditingController ctrl, IconData icon,
      {TextInputType? keyboardType}) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 18, color: AppColors.muted),
      ),
    );
  }
}
