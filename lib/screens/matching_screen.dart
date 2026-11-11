import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../repositories/repository_failure.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../state/ride_match.dart';
import '../state/ride_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/flow_scaffold.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

/// Finds nearby riders for the passenger's request and offers them one at a
/// time, closest first.
///
/// A proposal is not a booking: selecting a rider sends them the request and
/// returns the passenger to Home. The rider still answers, and the passenger
/// follows the answer from Home, Activity or the notification feed. This screen
/// deliberately has no path to the Live Trip; a trip only exists once a rider
/// accepts.
class MatchingScreen extends StatefulWidget {
  const MatchingScreen({super.key});

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen> {
  /// Riders already shown in this visit. "Find Another" keeps walking down the
  /// ranking, so the same person is never proposed twice.
  final Set<String> _seen = {};

  /// Riders this visit has seen, keyed by id. A hosted proposal is not in the
  /// seed fleet, so the sent-state card needs this local snapshot to name the
  /// rider after the proposal has been cleared.
  final Map<String, MapRider> _knownRiders = {};

  /// True while the request is being sent to the chosen rider.
  bool _sending = false;

  /// True between asking for a match and the answer landing. Separate from
  /// [AppState.rideProposal] because the previous proposal stays in the store
  /// until the next one replaces it.
  bool _searching = true;

  /// True once the search came back with nobody left to offering.
  bool _exhausted = false;

  AppState get state => AppState.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final request = state.myRideRequest;
      if (request != null) state.syncRideRoute(request);
      unawaited(_dispatch());
    });
  }

  /// Runs one dispatch round.
  ///
  /// The pause simulates a real round-trip; nothing depends on it, because the
  /// candidate list lives in [AppState]. [nextCandidate] adds the current
  /// proposal to the exclusion set first, which is what makes "Find Another"
  /// advance instead of repeating.
  Future<void> _dispatch({bool nextCandidate = false}) async {
    if (nextCandidate) {
      final proposal = state.rideProposal;
      if (proposal != null) _seen.add(proposal.rider.id);
    }
    if (mounted) {
      setState(() {
        _searching = true;
        _exhausted = false;
      });
    }
    await Future.delayed(Duration(milliseconds: nextCandidate ? 250 : 900));
    if (!mounted) return;
    final request = state.myRideRequest;
    if (request == null) {
      setState(() => _searching = false);
      return;
    }
    try {
      final outcome = state.usesHostedRideDispatch
          ? await state.proposeHostedRider(request, excludeRiderIds: _seen)
          : state.proposeRider(request, excludeRiderIds: _seen);
      final proposal = state.rideProposal;
      if (proposal != null) _knownRiders[proposal.rider.id] = proposal.rider;
      if (!mounted) return;
      setState(() {
        _searching = false;
        _exhausted = outcome == MatchOutcome.noRidersAvailable;
      });
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _exhausted = true;
      });
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Matching failed',
      );
    }
  }

  /// Sends the request to the proposed rider and goes home.
  ///
  /// Nothing here accepts on the rider's behalf: the request becomes
  /// [RideStatus.awaitingAcceptance] and waits for their answer.
  Future<void> _select(RideMatchProposal proposal) async {
    if (_sending) return;
    final riderName = proposal.riderName;
    setState(() => _sending = true);
    try {
      final sent = state.usesHostedRideDispatch
          ? await state.confirmHostedRideMatch()
          : state.confirmRideMatch();
      if (!sent || !mounted) return;
      SurgoNotice.show(
        context,
        'Request sent to $riderName. The trip starts once they accept.',
        tone: SbNoticeTone.success,
        title: 'Request sent',
      );
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Rider unavailable',
      );
      // The rider may have gone offline since the proposal. Look again rather
      // than leaving a card that can never be selected.
      unawaited(_dispatch(nextCandidate: true));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Closes the screen, putting the request back to open so it can be matched
  /// again later instead of pointing at a rider nobody chose.
  void _close() {
    if (state.usesHostedRideDispatch) {
      unawaited(state.cancelHostedRideRequest(reason: 'Closed matching'));
    } else {
      state.declineRideMatch();
    }
    Navigator.pop(context);
  }

  void _backHome() {
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
  }

  void _previewDemoTrip() {
    if (_sending || state.usesHostedRideDispatch) return;
    final request = state.myRideRequest;
    if (request == null || !state.confirmRideMatch()) return;
    state.riderAccepts(request);
    if (state.activeRide == request) {
      Navigator.pushReplacementNamed(context, '/livetrip');
    }
  }

  void _cancelRequest() {
    if (state.usesHostedRideDispatch) {
      unawaited(
        state.cancelHostedRideRequest(reason: 'Cancelled by passenger'),
      );
    } else {
      state.cancelRideRequest();
    }
    _backHome();
  }

  MapRider? _riderFor(String? id) {
    if (id == null) return null;
    final known = _knownRiders[id];
    if (known != null) return known;
    for (final rider in state.db.mapRiders) {
      if (rider.id == id) return rider;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _buildFlow(context),
  );

  Widget _buildFlow(BuildContext context) {
    final request = state.myRideRequest;
    if (request == null) return _noRequest();
    if (request.status == RideStatus.awaitingAcceptance) {
      return _shell(
        title: 'Request sent',
        stateKey: 'sent',
        body: _sent(request),
        onBack: _backHome,
      );
    }
    final proposal = state.rideProposal;
    if (_searching || (proposal == null && !_exhausted)) {
      return _shell(
        title: 'Finding a ride',
        stateKey: 'searching',
        body: _searchingBody(request),
        onBack: _close,
      );
    }
    if (_exhausted || proposal == null) {
      return _shell(
        title: 'No riders nearby',
        stateKey: 'exhausted',
        body: _noRiders(),
        onBack: _close,
      );
    }
    return _shell(
      title: 'Rider found',
      stateKey: proposal.rider.id,
      onBack: _close,
      body: Column(
        children: [
          Expanded(child: _proposal(request, proposal)),
          _proposalActions(proposal),
        ],
      ),
    );
  }

  Widget _shell({
    required String title,
    required Object stateKey,
    required Widget body,
    required VoidCallback onBack,
  }) {
    final request = state.myRideRequest!;
    final pickup =
        request.pickupLatitude == null || request.pickupLongitude == null
        ? null
        : MapPoint(request.pickupLatitude!, request.pickupLongitude!);
    final destination =
        request.dropoffLatitude == null || request.dropoffLongitude == null
        ? null
        : MapPoint(request.dropoffLatitude!, request.dropoffLongitude!);
    final proposal = _searching ? null : state.rideProposal;
    return SbFlowScaffold(
      title: title,
      stateKey: stateKey,
      onBack: onBack,
      sheetFraction: 0.62,
      map: SurgoMap(
        height: MediaQuery.sizeOf(context).height,
        borderRadius: BorderRadius.zero,
        showUserLocation: false,
        fallbackCenter: pickup ?? state.db.mapConfig.defaultCenter,
        cameraPadding: EdgeInsets.fromLTRB(
          24,
          80,
          24,
          MediaQuery.sizeOf(context).height * 0.62 + 20,
        ),
        routeIsEstimate: state.rideRouting.route == null,
        route:
            state.rideRouting.route?.points ??
            [
              if (pickup != null && destination != null) ...[
                pickup,
                destination,
              ],
            ],
        markers: [
          if (pickup != null)
            SurgoMapMarker(
              id: 'pickup',
              position: pickup,
              icon: Icons.person_pin_circle_outlined,
              title: 'Pickup',
              subtitle: request.pickup,
            ),
          if (destination != null)
            SurgoMapMarker(
              id: 'destination',
              position: destination,
              icon: Icons.place_outlined,
              title: 'Destination',
              subtitle: request.dropoff,
              color: const Color(0xFFFFB84D),
            ),
          if (proposal != null)
            SurgoMapMarker(
              id: proposal.rider.id,
              position: proposal.rider.position,
              icon: surgoMarkerIcon(proposal.rider.vehicleType),
              title: proposal.riderName,
              subtitle: proposal.rider.isSimulated
                  ? 'Simulated position'
                  : 'Last shared rider position',
            ),
        ],
      ),
      sheet: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: SbFlowStepper(
              labels: const ['Choose', 'Search', 'Rider', 'Pickup', 'Trip'],
              activeStep: _searching ? 1 : 2,
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _searchingBody(RideRequestItem request) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SbSearchRadar(size: 110),
          const SizedBox(height: 22),
          const Text(
            'Finding you a rider…',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            'Looking for available, verified riders near ${request.pickup}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          Text(
            '${request.pickup} → ${request.dropoff}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted2, fontSize: 11.5),
          ),
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

  /// Shown when the search came back empty, either because nobody is free or
  /// because every candidate was already offered and turned down.
  Widget _noRiders() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.person_off_outlined,
              size: 40,
              color: AppColors.muted2,
            ),
            const SizedBox(height: 14),
            const Text(
              'No riders available',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              state.usesHostedRideDispatch
                  ? 'No rider is online and available right now. '
                        'Search again, or go back and change your route.'
                  : 'No other verified rider is free near your pickup right '
                        'now. Search again in a moment, or go back and change '
                        'your route.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Search again',
              block: false,
              onPressed: () {
                _seen.clear();
                unawaited(_dispatch());
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _cancelRequest,
              style: TextButton.styleFrom(foregroundColor: AppColors.muted),
              child: const Text('Cancel this request'),
            ),
          ],
        ),
      ),
    );
  }

  /// The rider's card: who they are, what they drive, how far away they are,
  /// and what the trip costs before the passenger selects them.
  Widget _proposal(RideRequestItem request, RideMatchProposal proposal) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        SbStatusBanner(
          tone: SbTone.info,
          icon: Icons.science_outlined,
          title: state.usesHostedRideDispatch
              ? (proposal.rider.isSimulated
                    ? 'Simulated position, live availability'
                    : 'Live rider availability')
              : 'Simulated rider fleet',
          message: state.usesHostedRideDispatch
              ? (proposal.rider.isSimulated
                    ? 'Availability comes from the database; this rider’s position is simulated, not device GPS.'
                    : 'This is the rider’s last shared position. Live trip tracking starts after they accept.')
              : 'Rider positions and ETAs come from the demo fleet in this '
                    'build. They are not live riders and not a real dispatch.',
        ),
        const SizedBox(height: 14),
        const Text(
          'Closest rider first',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
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
                        Text(
                          proposal.riderName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          proposal.rider.vehiclePlate.trim().isEmpty
                              ? proposal.vehicleLabel
                              : '${proposal.vehicleLabel} · '
                                    '${proposal.rider.vehiclePlate}',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
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
                  _fact(
                    Icons.star_rounded,
                    proposal.rider.rating.toStringAsFixed(1),
                    'rating',
                  ),
                  _fact(Icons.schedule, '${proposal.etaMinutes} min', 'ETA'),
                  _fact(Icons.near_me, proposal.distanceLabel, 'distance'),
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
        // Say what happens next before it happens. Selecting is not accepting,
        // and the passenger is about to leave this screen.
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
              const Icon(
                Icons.info_outline,
                size: 16,
                color: AppColors.primaryLight,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Selecting sends your request to ${proposal.riderName}. '
                  'The trip only starts when they accept, and you can follow '
                  'the request from Home or Activity.',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                    height: 1.5,
                  ),
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
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _proposalActions(RideMatchProposal proposal) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: SbOutlineButton(
                    label: 'Find Another',
                    onPressed: _sending
                        ? null
                        : () => unawaited(_dispatch(nextCandidate: true)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SbPrimaryButton(
                    label: 'Select Rider',
                    foreground: Colors.white,
                    icon: Icons.check_rounded,
                    feedback: _sending
                        ? SbButtonFeedback.loading
                        : SbButtonFeedback.idle,
                    onPressed: _sending
                        ? null
                        : () => unawaited(_select(proposal)),
                  ),
                ),
              ],
            ),
            if (!state.usesHostedRideDispatch)
              TextButton.icon(
                onPressed: _sending ? null : _previewDemoTrip,
                icon: const Icon(Icons.science_outlined, size: 16),
                label: const Text('Preview demo trip'),
              ),
          ],
        ),
      ),
    );
  }

  /// The state a passenger comes back to after a request was sent: who has it
  /// and that nobody has accepted yet.
  Widget _sent(RideRequestItem request) {
    final rider = _riderFor(request.riderId);
    final name = rider?.name;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.send_rounded,
              size: 40,
              color: AppColors.primaryLight,
            ),
            const SizedBox(height: 14),
            const Text(
              'Request sent',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              name == null
                  ? 'Your request is waiting for the rider to accept.'
                  : 'Your request went to $name and is waiting for them to '
                        'accept.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            SbCard(
              child: Column(
                children: [
                  _tripRow('Pick-up', request.pickup),
                  const Divider(height: 18, color: AppColors.border),
                  _tripRow('Destination', request.dropoff),
                  const Divider(height: 18, color: AppColors.border),
                  _tripRow('Status', RideStatus.awaitingAcceptance.label),
                  const Divider(height: 18, color: AppColors.border),
                  _tripRow('Fare', Money.format(request.fare)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SbOutlineButton(label: 'Back to Home', onPressed: _backHome),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _cancelRequest,
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Cancel request'),
            ),
          ],
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
          child: Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
          ),
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
            const Icon(
              Icons.search_off_rounded,
              size: 40,
              color: AppColors.muted2,
            ),
            const SizedBox(height: 14),
            const Text(
              'No active request',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              'This request is no longer being matched.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            SbOutlineButton(
              label: 'Back to Home',
              block: false,
              onPressed: _backHome,
            ),
          ],
        ),
      ),
    );
  }
}
