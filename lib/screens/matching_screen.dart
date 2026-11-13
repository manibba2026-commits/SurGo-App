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
import '../widgets/route_preview.dart';
import '../widgets/surfaces.dart';
import '../widgets/surgo_map.dart';
import '../widgets/surgo_notice.dart';

/// Finds nearby riders and follows the passenger's request through assignment.
/// Selecting sends an offer; only the rider's acceptance unlocks the live trip.
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
  bool _cancelling = false;
  RepositoryFailure? _cancelFailure;

  /// True between asking for a match and the answer landing. Separate from
  /// [AppState.rideProposal] because the previous proposal stays in the store
  /// until the next one replaces it.
  bool _searching = true;

  /// True once the search came back with nobody left to offering.
  bool _exhausted = false;

  AppState get state => AppState.instance;

  String? _observedRequestId;
  RideStatus? _observedStatus;
  String? _observedRiderId;
  int _requestRevision = 0;
  bool _dispatchRunning = false;

  /// True once this screen handed the trip to the live-trip route, so the
  /// acceptance listener cannot push it twice while the route animates.
  bool _openingLiveTrip = false;

  @override
  void initState() {
    super.initState();
    final request = state.myRideRequest;
    _observedRequestId = request?.id;
    _observedStatus = request?.status;
    _observedRiderId = request?.riderId;
    state.addListener(_onRequestChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final request = state.myRideRequest;
      if (request != null) state.syncRideRoute(request);
      if (request?.status == RideStatus.searching) unawaited(_dispatch());
      // Reopening this screen on a request the rider already accepted must land
      // on the trip, not on a read-only "request sent" card.
      _enterLiveTripIfCommitted();
    });
  }

  @override
  void dispose() {
    state.removeListener(_onRequestChanged);
    super.dispose();
  }

  /// Follows the passenger's request into the live trip the moment the rider
  /// accepts.
  ///
  /// Acceptance arrives through the passenger session's realtime read, which
  /// updates [AppState.myRideRequest] without any tap here. Only a hosted build
  /// can receive it asynchronously; the seeded build keeps its explicit
  /// "Preview demo trip" handoff.
  void _enterLiveTripIfCommitted() {
    if (_openingLiveTrip || !state.usesHostedRideDispatch) return;
    final request = state.myRideRequest;
    if (request == null ||
        !request.status.isCommitted ||
        request.status.isTerminal) {
      return;
    }
    _openingLiveTrip = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _openingLiveTrip = false;
        return;
      }
      Navigator.pushReplacementNamed(context, '/livetrip');
    });
  }

  void _onRequestChanged() {
    final request = state.myRideRequest;
    if (request?.id == _observedRequestId &&
        request?.status == _observedStatus) {
      return;
    }
    if (request?.id != _observedRequestId) {
      _seen.clear();
      _knownRiders.clear();
    } else if (request?.status == RideStatus.searching &&
        _observedRiderId != null) {
      _seen.add(_observedRiderId!);
    }
    _observedRequestId = request?.id;
    _observedStatus = request?.status;
    _observedRiderId = request?.riderId;
    _requestRevision++;
    if (request?.status == RideStatus.searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_dispatch());
      });
    }
    // The rider answered while this screen was open: the trip is now active.
    _enterLiveTripIfCommitted();
  }

  Future<void> _dispatch({bool nextCandidate = false}) async {
    final request = state.myRideRequest;
    if (!mounted ||
        _dispatchRunning ||
        _cancelling ||
        request == null ||
        request.status != RideStatus.searching) {
      return;
    }
    _dispatchRunning = true;
    final revision = _requestRevision;
    bool stillSearching() =>
        revision == _requestRevision &&
        state.myRideRequest?.id == request.id &&
        state.myRideRequest?.status == RideStatus.searching;

    try {
      if (nextCandidate) {
        final proposal = state.rideProposal;
        if (proposal != null) _seen.add(proposal.rider.id);
      }
      setState(() {
        _searching = true;
        _exhausted = false;
      });
      await Future.delayed(Duration(milliseconds: nextCandidate ? 250 : 900));
      if (!mounted) return;
      if (_cancelling || !stillSearching()) {
        setState(() => _searching = false);
        return;
      }
      final outcome = state.usesHostedRideDispatch
          ? await state.proposeHostedRider(request, excludeRiderIds: _seen)
          : state.proposeRider(request, excludeRiderIds: _seen);
      if (!mounted) return;
      if (!stillSearching()) {
        setState(() => _searching = false);
        return;
      }
      final proposal = state.rideProposal;
      if (proposal != null) _knownRiders[proposal.rider.id] = proposal.rider;
      setState(() {
        _searching = false;
        _exhausted = outcome == MatchOutcome.noRidersAvailable;
      });
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() => _searching = false);
      if (!stillSearching()) return;
      setState(() => _exhausted = true);
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Matching failed',
      );
    } finally {
      _dispatchRunning = false;
      if (mounted &&
          revision != _requestRevision &&
          state.myRideRequest?.status == RideStatus.searching) {
        unawaited(_dispatch());
      }
    }
  }

  /// Sends an offer without accepting on the rider's behalf or leaving matching.
  Future<void> _select(RideMatchProposal proposal) async {
    if (_sending ||
        _cancelling ||
        state.myRideRequest?.status != RideStatus.searching ||
        state.myRideRequest?.id != proposal.requestId) {
      return;
    }
    final riderName = proposal.riderName;
    _knownRiders[proposal.rider.id] = proposal.rider;
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

  /// Leaving is not cancellation: Home can resume this same request.
  void _backHome() {
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
  }

  void _previewDemoTrip() {
    if (_sending || state.usesHostedRideDispatch) return;
    final request = state.myRideRequest;
    if (request == null) return;
    if (request.status == RideStatus.searching && !state.confirmRideMatch()) {
      return;
    }
    if (request.status != RideStatus.awaitingAcceptance) return;
    state.riderAccepts(request);
    if (state.activeRide == request) {
      Navigator.pushReplacementNamed(context, '/livetrip');
    }
  }

  Future<void> _cancelRequest() async {
    final request = state.myRideRequest;
    if (_cancelling ||
        _sending ||
        request == null ||
        request.status.isTerminal) {
      return;
    }
    setState(() {
      _cancelling = true;
      _cancelFailure = null;
    });
    try {
      if (state.usesHostedRideDispatch) {
        await state.cancelHostedRideRequest(reason: 'Cancelled by passenger');
      } else {
        state.cancelRideRequest();
      }
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() => _cancelFailure = failure);
      SurgoNotice.show(
        context,
        failure.message,
        tone: SbNoticeTone.warning,
        title: 'Cancellation failed',
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  MapRider? _riderFor(String? id) {
    if (id == null) return null;
    final known = _knownRiders[id];
    if (known != null) return known;
    if (state.usesHostedRideDispatch) return null;
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
    if (request.status != RideStatus.searching) {
      return _shell(
        title: request.status == RideStatus.awaitingAcceptance
            ? 'Request sent'
            : request.status.label,
        stateKey: request.status,
        body: _sent(request),
        onBack: _backHome,
      );
    }
    final currentProposal = state.rideProposal;
    final proposal = currentProposal?.requestId == request.id
        ? currentProposal
        : null;
    if (_searching || (proposal == null && !_exhausted)) {
      return _shell(
        title: 'Finding a ride',
        stateKey: 'searching',
        body: _searchingBody(request),
        onBack: _backHome,
      );
    }
    if (_exhausted || proposal == null) {
      return _shell(
        title: 'No riders nearby',
        stateKey: 'exhausted',
        body: _noRiders(),
        onBack: _backHome,
      );
    }
    return _shell(
      title: 'Rider found',
      stateKey: proposal.rider.id,
      onBack: _backHome,
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
    final currentProposal = state.rideProposal;
    final proposal =
        !_searching &&
            request.status == RideStatus.searching &&
            currentProposal?.requestId == request.id
        ? currentProposal
        : null;
    return SbFlowScaffold(
      title: title,
      stateKey: stateKey,
      onBack: onBack,
      sheetFraction: 0.62,
      map: SurgoMap(
        height: MediaQuery.sizeOf(context).height * 0.38,
        borderRadius: BorderRadius.zero,
        showUserLocation: false,
        fallbackCenter: pickup ?? state.db.mapConfig.defaultCenter,
        pulseCenter: _searching ? pickup : null,
        cameraPadding: const EdgeInsets.fromLTRB(24, 80, 24, 20),
        routeIsEstimate: state.rideRouting.route == null,
        routeColor: proposal == null
            ? SurgoMap.defaultRouteColor
            : AppColors.success,
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
              labels: const [
                'Destination',
                'Search',
                'Rider',
                'Pickup',
                'Trip',
              ],
              activeStep: switch (request.status) {
                RideStatus.searching => _searching ? 1 : 2,
                RideStatus.awaitingAcceptance || RideStatus.cancelled => 2,
                RideStatus.accepted ||
                RideStatus.headingToPickup ||
                RideStatus.arrived => 3,
                RideStatus.inProgress || RideStatus.completed => 4,
              },
            ),
          ),
          if (_cancelFailure != null || state.passengerRideFailure != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _failureNotice(),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _failureNotice() {
    final failure = _cancelFailure ?? state.passengerRideFailure!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SbStatusBanner(
          tone: SbTone.warning,
          icon: Icons.warning_amber_rounded,
          title: _cancelFailure != null
              ? 'Cancellation failed'
              : 'Request update unavailable',
          message: failure.message,
        ),
        if (state.usesHostedRideDispatch)
          TextButton(
            onPressed: state.passengerRideLoading
                ? null
                : () => unawaited(state.refreshPassengerRide()),
            child: Text(
              state.passengerRideLoading
                  ? 'Refreshing request…'
                  : 'Refresh request',
            ),
          ),
      ],
    );
  }

  Widget _searchingBody(RideRequestItem request) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      children: [
        Column(
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
              label: _cancelling ? 'Cancelling…' : 'Cancel request',
              block: false,
              onPressed: _cancelling ? null : _cancelRequest,
            ),
            TextButton(onPressed: _backHome, child: const Text('Back to Home')),
          ],
        ),
      ],
    );
  }

  /// Shown when the search came back empty, either because nobody is free or
  /// because every candidate was already offered and turned down.
  Widget _noRiders() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Column(
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
              onPressed: _cancelling
                  ? null
                  : () {
                      _seen.clear();
                      unawaited(_dispatch());
                    },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _cancelling ? null : _cancelRequest,
              style: TextButton.styleFrom(foregroundColor: AppColors.muted),
              child: Text(_cancelling ? 'Cancelling…' : 'Cancel this request'),
            ),
            TextButton(onPressed: _backHome, child: const Text('Back to Home')),
          ],
        ),
      ],
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
        if (request.pickupLatitude != null &&
            request.pickupLongitude != null &&
            request.dropoffLatitude != null &&
            request.dropoffLongitude != null) ...[
          const SizedBox(height: 14),
          SbRoutePreview(
            start: MapPoint(
              request.pickupLatitude!,
              request.pickupLongitude!,
            ),
            end: MapPoint(
              request.dropoffLatitude!,
              request.dropoffLongitude!,
            ),
            route: state.rideRouting.route?.points ?? const [],
            startLabel: 'Pickup',
            endLabel: 'Destination',
          ),
        ],
        const SizedBox(height: 14),
        SbCard(
          child: Column(
            children: [
              _tripRow('Passenger', request.passengerName),
              if (request.note.isNotEmpty) ...[
                const Divider(height: 18, color: AppColors.border),
                _tripRow('Booking details', request.note),
              ],
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Pick-up', request.pickup),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Destination', request.dropoff),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Fare', Money.format(proposal.fare)),
            ],
          ),
        ),
        const SizedBox(height: 14),
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
                  'Stay here for their answer, then open the live trip '
                  'once they accept.',
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
            TextButton(onPressed: _backHome, child: const Text('Back to Home')),
          ],
        ),
      ),
    );
  }

  Widget _sent(RideRequestItem request) {
    final recordedName = request.riderName?.trim();
    final name = recordedName != null && recordedName.isNotEmpty
        ? recordedName
        : _riderFor(request.riderId)?.name;
    final price = state.priceFor(request);
    final status = request.status;
    final message = switch (status) {
      RideStatus.awaitingAcceptance =>
        name == null
            ? 'Your request is waiting for the rider to accept.'
            : 'Your request went to $name and is waiting for them to accept.',
      RideStatus.accepted =>
        'Your rider accepted. Open the live trip for pickup updates.',
      RideStatus.headingToPickup => 'Your rider is heading to your pickup.',
      RideStatus.arrived => 'Your rider has arrived at your pickup.',
      RideStatus.inProgress =>
        'Your trip is in progress. Open the live trip for updates.',
      RideStatus.completed =>
        'Your trip is complete. View your receipt and rate the trip.',
      RideStatus.cancelled => 'This request was cancelled.',
      RideStatus.searching => 'Looking for an available rider.',
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      children: [
        Icon(
          status == RideStatus.completed
              ? Icons.receipt_long_outlined
              : status == RideStatus.cancelled
              ? Icons.cancel_outlined
              : status == RideStatus.awaitingAcceptance
              ? Icons.send_rounded
              : Icons.directions_car_outlined,
          size: 36,
          color: AppColors.primaryLight,
        ),
        const SizedBox(height: 12),
        Text(
          status == RideStatus.awaitingAcceptance
              ? 'Request sent'
              : status.label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 16),
        SbCard(
          child: Column(
            children: [
              _tripRow('Passenger', request.passengerName),
              if (request.note.isNotEmpty) ...[
                const Divider(height: 18, color: AppColors.border),
                _tripRow('Booking details', request.note),
              ],
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Pick-up', request.pickup),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Destination', request.dropoff),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Rider', name ?? 'Not available'),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Status', status.label),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Payment', request.paymentMethod),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Fare', price.providerFareLabel),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Platform fee', price.platformFeeLabel),
              const Divider(height: 18, color: AppColors.border),
              _tripRow('Customer total', price.customerTotalLabel),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (status.isCommitted && !status.isTerminal) ...[
          SbPrimaryButton(
            label: 'View live trip',
            onPressed: () => Navigator.pushNamed(context, '/livetrip'),
          ),
          const SizedBox(height: 10),
        ],
        if (status == RideStatus.completed) ...[
          SbPrimaryButton(
            label: 'View receipt',
            onPressed: () => Navigator.pushNamed(context, '/rate'),
          ),
          const SizedBox(height: 10),
        ],
        if (!state.usesHostedRideDispatch &&
            status == RideStatus.awaitingAcceptance)
          TextButton.icon(
            onPressed: _previewDemoTrip,
            icon: const Icon(Icons.science_outlined, size: 16),
            label: const Text('Preview demo trip'),
          ),
        SbOutlineButton(label: 'Back to Home', onPressed: _backHome),
        if (state.usesHostedRideDispatch)
          TextButton(
            onPressed: state.passengerRideLoading
                ? null
                : () => unawaited(state.refreshPassengerRide()),
            child: Text(
              state.passengerRideLoading
                  ? 'Refreshing request…'
                  : 'Refresh request',
            ),
          ),
        if (!status.isTerminal)
          TextButton(
            onPressed: _cancelling || _sending ? null : _cancelRequest,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel request'),
          ),
      ],
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
