import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/ride_match.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';

/// Finds a rider for the passenger's request, then asks the passenger to accept
/// the one that was found.
///
/// The two are separate screens because they are separate commitments. A match
/// is a proposal; it becomes a booking when the passenger confirms, and a trip
/// only when the rider accepts too. This screen shows the first step and waits
/// for a decision rather than deciding for the passenger.
class MatchingScreen extends StatefulWidget {
  const MatchingScreen({super.key});

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinner;

  /// The result of the search. Null while still searching; the two terminal
  /// values let "nobody was free" be told apart from "here is a rider", which a
  /// single "finished" flag could not do without showing a confirm button that
  /// could never work.
  MatchOutcome? _outcome;

  /// Set once the passenger confirms, so the screen can show "waiting for the
  /// rider" rather than the proposal they already accepted.
  bool _confirmed = false;

  /// Fires the simulated rider acceptance after a pause, so the
  /// awaiting-acceptance state is actually visible. Guarded by [_confirmed]
  /// because it must not run for a request the passenger declined.
  Timer? _acceptTimer;

  @override
  void initState() {
    super.initState();
    _spinner = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    // The search delay simulates a real dispatch round-trip. Nothing depends on
    // it: the state lives in AppState, not in this timer, so if it never fires
    // the screen still shows the proposal.
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final request = AppState.instance.myRideRequest;
      if (request == null) return;
      final outcome = AppState.instance.proposeRider(request);
      if (mounted) setState(() => _outcome = outcome);
    });
  }

  @override
  void dispose() {
    _acceptTimer?.cancel();
    _spinner.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!AppState.instance.confirmRideMatch()) return;
    setState(() => _confirmed = true);

    // The rider's acceptance is somebody else's action, simulated on a delay so
    // the passenger sees the trip move on its own rather than jumping straight
    // to "accepted".
    _acceptTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final request = AppState.instance.myRideRequest;
      if (request == null) return;
      AppState.instance.riderAccepts(request);
    });
  }

  void _decline() {
    _acceptTimer?.cancel();
    AppState.instance.declineRideMatch();
    Navigator.pop(context);
  }

  void _cancelRequest() {
    _acceptTimer?.cancel();
    AppState.instance.cancelRideRequest();
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
  }

  void _goToTrip() {
    Navigator.pushReplacementNamed(context, '/livetrip');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final request = state.myRideRequest;
    final proposal = state.rideProposal;

    // Nothing to match: the request was cancelled or never created. Say so
    // instead of showing an eternal spinner.
    if (request == null) {
      return _noRequest();
    }

    // The passenger confirmed and the rider has not answered yet.
    if (_confirmed) {
      return _waiting(request);
    }

    // Searching finished with nobody to offer: say that instead of rendering a
    // proposal that does not exist, and drop the confirm action entirely.
    final empty = _outcome == MatchOutcome.noRidersAvailable;

    if (empty) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('No riders yet'),
          leading: SbIconButton(icon: Icons.close, onTap: _decline),
        ),
        body: _noRiders(),
      );
    }

    if (proposal == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Finding a ride'),
          leading: SbIconButton(icon: Icons.close, onTap: _decline),
        ),
        body: _searching(request),
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Ride found'),
        leading: SbIconButton(icon: Icons.close, onTap: _decline),
      ),
      body: _proposal(context, request, proposal),
      bottomNavigationBar: _searchActions(context),
    );
  }

  Widget _searching(RideRequestItem request) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 110,
            height: 110,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.panel2, width: 3),
                  ),
                ),
                RotationTransition(
                  turns: _spinner,
                  child: const SizedBox(
                    width: 110,
                    height: 110,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor:
                          AlwaysStoppedAnimation(AppColors.primary),
                      backgroundColor: Colors.transparent,
                      value: 0.25,
                    ),
                  ),
                ),
                const Icon(Icons.electric_rickshaw,
                    size: 36, color: AppColors.primaryLight),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text('Finding you a ride…',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          Text('Looking for a ${AppState.instance.rideOptionName} nearby',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          const SizedBox(height: 6),
          Text('${request.pickup} → ${request.dropoff}',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: AppColors.muted2, fontSize: 11.5)),
          const SizedBox(height: 26),
          SbOutlineButton(
            label: 'Cancel request',
            block: false,
            onPressed: _cancelRequest,
          ),
        ],
      ),
    );
  }

  /// Shown when the search finished but produced no rider: either the proposal
  /// was declined, or nobody was free. Both need the same recovery, which is to
  /// change the request and try again.
  Widget _noRiders() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined,
                size: 40, color: AppColors.muted2),
            const SizedBox(height: 14),
            const Text('No riders available',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            const Text(
              'Nobody free is nearby right now. Try again in a moment, or '
              'pick a different vehicle type.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Back to Home',
              block: false,
              onPressed: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil('/home', (route) => false),
            ),
          ],
        ),
      ),
    );
  }

  /// Between the passenger confirming and the rider accepting.
  Widget _waiting(RideRequestItem request) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Request sent'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    RotationTransition(
                      turns: _spinner,
                      child: const SizedBox(
                        width: 72,
                        height: 72,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.primary),
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    ),
                    const Icon(Icons.send_rounded,
                        size: 26, color: AppColors.primaryLight),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('Waiting for your rider',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                'Your request went to ${request.riderId ?? 'the nearest rider'}. '
                'The trip starts once they accept.',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              SbCard(
                child: Column(
                  children: [
                    _tripRow('Status', RideStatus.awaitingAcceptance.label),
                    const Divider(height: 18, color: AppColors.border),
                    _tripRow('Fare', Money.format(request.fare)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SbOutlineButton(
                label: 'Cancel request',
                onPressed: _cancelRequest,
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _waitingActions(),
    );
  }

  /// The proposal: who is driving, what they drive, how far, and what it costs.
  ///
  /// Everything the passenger needs to decide is here, because once they confirm
  /// the rider is dispatched and this screen is gone.
  Widget _proposal(BuildContext context, RideRequestItem request,
      RideMatchProposal proposal) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        const Text('Your rider',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
        const SizedBox(height: 10),
        SbCard(
          borderColor: AppColors.primary,
          child: Column(
            children: [
              Row(
                children: [
                  SbAvatar(initials: proposal.initials, size: 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(proposal.riderName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                          '${proposal.vehicleLabel} · ${proposal.plateLabel}',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (proposal.rider.verified)
                    const SbTag('Verified', secondary: true),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _fact(Icons.star_rounded,
                      proposal.rider.rating.toStringAsFixed(1), 'rating'),
                  _fact(
                      Icons.schedule, '${proposal.etaMinutes} min', 'ETA'),
                  _fact(Icons.near_me, proposal.distanceLabel, 'away'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SbCard(
          child: Column(
            children: [
              _tripRow('Pick-up', request.pickup),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Destination', request.dropoff),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Fare', Money.format(proposal.fare)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Say what happens next before it happens. The passenger is being asked
        // to commit, so they get to know the rider has not agreed yet.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.panel2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline,
                  size: 16, color: AppColors.primaryLight),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Confirming sends your request to ${proposal.riderName}. '
                  'The trip starts when they accept.',
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 11.5, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fact(IconData icon, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 16, color: AppColors.primaryLight),
          const SizedBox(height: 5),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 1),
          Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _searchActions(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: SbOutlineButton(
                label: 'Not this one',
                onPressed: _decline,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: SbPrimaryButton(
                label: 'Confirm rider',
                icon: Icons.check_rounded,
                onPressed: _confirm,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waitingActions() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SbPrimaryButton(
          label: 'View trip',
          icon: Icons.map_outlined,
          onPressed: _goToTrip,
        ),
      ),
    );
  }

  Widget _tripRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 12.5)),
        ),
      ],
    );
  }

  Widget _noRequest() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 40, color: AppColors.muted2),
            const SizedBox(height: 14),
            const Text('No active request',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('This request is no longer being matched.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Back to Home',
              block: false,
              onPressed: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil('/home', (route) => false),
            ),
          ],
        ),
      ),
    );
  }
}