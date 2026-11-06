/// The lifecycle of a Pasuyo errand, as one legal path.
///
/// The machine starts at [available]: an errand becomes visible to helpers the
/// moment it is created, so there is no separate "posted" wait state to render.
/// [delivered] is the terminal state and the helper's last action — there is no
/// second customer confirmation step between arrival and completion.
///
/// `next` is the only way forward, so the feed card and the details screen can
/// never disagree about what comes next.
enum PasuyoStatus {
  available,
  accepted,
  goingToPickup,
  atPickup,
  pickedUp,
  delivering,
  atCustomer,
  delivered,
  cancelled;

  /// The single legal successor, or null at a terminal state.
  PasuyoStatus? get next => switch (this) {
        PasuyoStatus.available => PasuyoStatus.accepted,
        PasuyoStatus.accepted => PasuyoStatus.goingToPickup,
        PasuyoStatus.goingToPickup => PasuyoStatus.atPickup,
        PasuyoStatus.atPickup => PasuyoStatus.pickedUp,
        PasuyoStatus.pickedUp => PasuyoStatus.delivering,
        PasuyoStatus.delivering => PasuyoStatus.atCustomer,
        PasuyoStatus.atCustomer => PasuyoStatus.delivered,
        PasuyoStatus.delivered || PasuyoStatus.cancelled => null,
      };

  /// The helper's next action, or null when nothing is pressable: the errand is
  /// still unclaimed, or it is already finished.
  String? get advanceActionLabel => switch (this) {
        PasuyoStatus.available => 'Accept task',
        PasuyoStatus.accepted => "I'm heading to pickup",
        PasuyoStatus.goingToPickup => "I've arrived at pickup",
        PasuyoStatus.atPickup => 'Mark as picked up / purchased',
        PasuyoStatus.pickedUp => "I'm heading to the customer",
        PasuyoStatus.delivering => "I've arrived",
        PasuyoStatus.atCustomer => 'Mark delivered',
        PasuyoStatus.delivered || PasuyoStatus.cancelled => null,
      };

  /// Full sentence for the status line.
  String get label => switch (this) {
        PasuyoStatus.available => 'Waiting for a helper',
        PasuyoStatus.accepted => 'Helper assigned',
        PasuyoStatus.goingToPickup => 'Helper is heading to pickup',
        PasuyoStatus.atPickup => 'Helper is at the pickup',
        PasuyoStatus.pickedUp => 'Items collected',
        PasuyoStatus.delivering => 'On the way',
        PasuyoStatus.atCustomer => 'Helper has arrived',
        PasuyoStatus.delivered => 'Delivered',
        PasuyoStatus.cancelled => 'Cancelled',
      };

  /// Short form for dense chips, where [label] would wrap.
  String get shortLabel => switch (this) {
        PasuyoStatus.available => 'Available',
        PasuyoStatus.accepted => 'Accepted',
        PasuyoStatus.goingToPickup => 'To pickup',
        PasuyoStatus.atPickup => 'At pickup',
        PasuyoStatus.pickedUp => 'Collected',
        PasuyoStatus.delivering => 'On the way',
        PasuyoStatus.atCustomer => 'Arrived',
        PasuyoStatus.delivered => 'Completed',
        PasuyoStatus.cancelled => 'Cancelled',
      };

  /// The helper who can act is already assigned and the errand is unfinished.
  bool get isTerminal =>
      this == PasuyoStatus.delivered || this == PasuyoStatus.cancelled;

  /// Nobody has claimed it yet, so it belongs in the public feed.
  bool get isOpen => this == PasuyoStatus.available;

  /// Claimed and unfinished. This is what gates taking on more work: an
  /// unclaimed errand is not a helper's task, so it must not count as one.
  bool get isActive => !isTerminal && !isOpen;

  /// Position along the visible path, or -1 when there is no path to be on.
  ///
  /// A cancelled errand never entered the path, so -1 is the honest answer and
  /// lets callers render "Cancelled" instead of clamping to step 1 and implying
  /// the errand had started.
  int get stepIndex => isTerminal && this == PasuyoStatus.cancelled
      ? -1
      : PasuyoStatus.flow.indexOf(this);

  /// Progress label for the stepper, e.g. "Step 2 of 7".
  ///
  /// A cancelled errand has no step, so it says so rather than reporting
  /// "Step 0 of 7" from the -1 in [stepIndex].
  String get stepLabel =>
      this == PasuyoStatus.cancelled ? 'Cancelled' : 'Step ${stepIndex + 1} of ${PasuyoStatus.flow.length}';

  /// The states shown by the progress stepper. Terminal states are excluded so
  /// the stepper never renders a step the errand cannot be on.
  static const List<PasuyoStatus> flow = [
    available,
    accepted,
    goingToPickup,
    atPickup,
    pickedUp,
    delivering,
    atCustomer,
    delivered,
  ];

  /// Parses a seeded status. Older seeds used a five-step vocabulary; those are
  /// mapped onto the new path by meaning, not by position, so seeded history
  /// still reads correctly:
  ///
  /// - `purchasing` meant the helper had the goods, so it maps to [pickedUp].
  /// - `completed` meant the errand was finished, so it maps to [delivered].
  static PasuyoStatus fromJson(Object? raw) => switch ('$raw'.toLowerCase()) {
        'posted' ||
        'available' ||
        'open' =>
          PasuyoStatus.available,
        'accepted' => PasuyoStatus.accepted,
        'purchasing' => PasuyoStatus.pickedUp,
        'delivering' => PasuyoStatus.delivering,
        'atpickup' || 'at_pickup' => PasuyoStatus.atPickup,
        'atcustomer' || 'at_customer' => PasuyoStatus.atCustomer,
        'completed' || 'delivered' => PasuyoStatus.delivered,
        'cancelled' || 'canceled' => PasuyoStatus.cancelled,
        _ => PasuyoStatus.available,
      };
}