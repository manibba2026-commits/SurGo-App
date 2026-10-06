/// The lifecycle of a ride request, as one legal path.
///
/// `next` is the only way forward, so a screen cannot invent a transition: it
/// asks the enum where the request goes and renders that, or nothing. Two
/// states sit between creation and commitment on purpose:
///
/// - [searching] the request exists but nobody is assigned yet.
/// - [awaitingAcceptance] a rider was *proposed* and the passenger confirmed
///   it, but the rider has not accepted yet.
///
/// Keeping those apart is what stops a match from reading as an acceptance.
enum RideStatus {
  searching,
  awaitingAcceptance,
  accepted,
  headingToPickup,
  arrived,
  inProgress,
  completed,
  cancelled;

  /// The single legal successor, or null at a terminal state.
  RideStatus? get next => switch (this) {
        RideStatus.searching => RideStatus.awaitingAcceptance,
        RideStatus.awaitingAcceptance => RideStatus.accepted,
        RideStatus.accepted => RideStatus.headingToPickup,
        RideStatus.headingToPickup => RideStatus.arrived,
        RideStatus.arrived => RideStatus.inProgress,
        RideStatus.inProgress => RideStatus.completed,
        RideStatus.completed || RideStatus.cancelled => null,
      };

  /// What the rider offers as the next action, or null when the move belongs
  /// to someone else (the passenger confirming, or a simulated rider
  /// accepting) and must not be pressable.
  String? get advanceActionLabel => switch (this) {
        RideStatus.accepted => 'Start heading to pickup',
        RideStatus.headingToPickup => "I've arrived at pickup",
        RideStatus.arrived => 'Start the trip',
        RideStatus.inProgress => 'Complete trip',
        RideStatus.searching ||
        RideStatus.awaitingAcceptance ||
        RideStatus.completed ||
        RideStatus.cancelled =>
          null,
      };

  /// Full sentence for the state badge and status line.
  String get label => switch (this) {
        RideStatus.searching => 'Finding a rider',
        RideStatus.awaitingAcceptance => 'Waiting for rider to accept',
        RideStatus.accepted => 'Rider accepted',
        RideStatus.headingToPickup => 'Heading to pickup',
        RideStatus.arrived => 'Arrived at pickup',
        RideStatus.inProgress => 'Trip in progress',
        RideStatus.completed => 'Completed',
        RideStatus.cancelled => 'Cancelled',
      };

  /// Short form for dense chips, where [label] would wrap.
  String get shortLabel => switch (this) {
        RideStatus.searching => 'Searching',
        RideStatus.awaitingAcceptance => 'Pending',
        RideStatus.accepted => 'Accepted',
        RideStatus.headingToPickup => 'En route',
        RideStatus.arrived => 'Arrived',
        RideStatus.inProgress => 'In trip',
        RideStatus.completed => 'Completed',
        RideStatus.cancelled => 'Cancelled',
      };

  /// A rider is assigned and the trip is under way.
  bool get isTerminal =>
      this == RideStatus.completed || this == RideStatus.cancelled;

  /// Nobody is assigned yet, so the request is still being matched.
  bool get isOpen => this == RideStatus.searching;

  /// Committed but not finished. This is what the rider's banner shows: a
  /// [searching] request is not yet this rider's problem.
  bool get isActive => !isTerminal && !isOpen;

/// Chat unlocks at [accepted] and stays open until the trip ends.
  ///
  /// False while searching or awaiting acceptance, because there is no agreed
  /// trip to talk about yet. False at [completed] and [cancelled] too: the trip
  /// is over, so the thread has nothing left to serve, and leaving it open would
  /// let a passenger keep messaging a rider about a finished ride.
  bool get allowsChat =>
      this != RideStatus.searching &&
      this != RideStatus.awaitingAcceptance &&
      !isTerminal;

  /// True once the passenger's money should be considered spent: the rider
  /// accepted, so cancelling is no longer a free option.
  bool get isCommitted => index >= RideStatus.accepted.index;

  /// Parses a seeded status. Older seeds stored free-text statuses; they are
  /// mapped onto the path rather than rewritten, so seed files stay valid.
  static RideStatus fromJson(Object? raw) => switch ('$raw'.toLowerCase()) {
        'pending' || 'searching' => RideStatus.searching,
        'awaitingacceptance' ||
        'awaiting_acceptance' ||
        'awaiting acceptance' =>
          RideStatus.awaitingAcceptance,
        'accepted' => RideStatus.accepted,
        'headingtopickup' ||
        'heading_to_pickup' ||
        'heading to pickup' =>
          RideStatus.headingToPickup,
        'arrived' => RideStatus.arrived,
        'inprogress' || 'in_progress' || 'in progress' => RideStatus.inProgress,
        'completed' => RideStatus.completed,
        'cancelled' || 'canceled' => RideStatus.cancelled,
        _ => RideStatus.searching,
      };
}