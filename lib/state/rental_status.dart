/// The lifecycle of a rental booking, as one legal path.
///
/// Return of the vehicle is the terminal event: [returned] settles into
/// [completed], and the owner's payout is released on that settle rather than on
/// the request being accepted. A booking therefore reads as four visible steps
/// — requested, accepted, out with the customer, returned — instead of a timer
/// flipping "Active" on its own.
enum RentalStatus {
  requested,
  awaitingOwner,
  accepted,
  active,
  returned,
  completed,
  declined,
  cancelled;

  /// The single legal successor, or null at a terminal state.
  RentalStatus? get next => switch (this) {
        RentalStatus.requested => RentalStatus.awaitingOwner,
        RentalStatus.awaitingOwner => RentalStatus.accepted,
        RentalStatus.accepted => RentalStatus.active,
        RentalStatus.active => RentalStatus.returned,
        RentalStatus.returned => RentalStatus.completed,
        RentalStatus.completed ||
        RentalStatus.declined ||
        RentalStatus.cancelled =>
          null,
      };

  /// The action that moves this booking forward, or null when the move belongs
  /// to someone else (the owner deciding) or the booking is finished.
  String? get advanceActionLabel => switch (this) {
        RentalStatus.requested => 'Send request to owner',
        RentalStatus.accepted => 'Pick up the vehicle',
        RentalStatus.active => 'Return the vehicle',
        RentalStatus.returned => 'Complete rental',
        RentalStatus.awaitingOwner ||
        RentalStatus.completed ||
        RentalStatus.declined ||
        RentalStatus.cancelled =>
          null,
      };

  /// Full sentence for the status line.
  String get label => switch (this) {
        RentalStatus.requested => 'Request sent',
        RentalStatus.awaitingOwner => 'Waiting for the owner',
        RentalStatus.accepted => 'Owner approved',
        RentalStatus.active => 'Out with the customer',
        RentalStatus.returned => 'Vehicle returned',
        RentalStatus.completed => 'Completed',
        RentalStatus.declined => 'Declined',
        RentalStatus.cancelled => 'Cancelled',
      };

  /// Short form for dense chips, where [label] would wrap.
  String get shortLabel => switch (this) {
        RentalStatus.requested => 'Requested',
        RentalStatus.awaitingOwner => 'Pending',
        RentalStatus.accepted => 'Approved',
        RentalStatus.active => 'Active',
        RentalStatus.returned => 'Returned',
        RentalStatus.completed => 'Completed',
        RentalStatus.declined => 'Declined',
        RentalStatus.cancelled => 'Cancelled',
      };

  bool get isTerminal =>
      this == RentalStatus.completed ||
      this == RentalStatus.declined ||
      this == RentalStatus.cancelled;

  /// The owner has not decided yet.
  bool get isPending =>
      this == RentalStatus.requested || this == RentalStatus.awaitingOwner;

  /// The vehicle is committed to the renter: it is off the owner's list and
  /// must not be offered to anyone else.
  bool get isOnRent =>
      this == RentalStatus.accepted ||
      this == RentalStatus.active ||
      this == RentalStatus.returned;

  /// The owner earns from [returned] onward, because the vehicle is back.
  bool get paysOut => this == RentalStatus.returned || this == RentalStatus.completed;

  /// Parses a seeded status. Older seeds stored free-text statuses.
  static RentalStatus fromJson(Object? raw) => switch ('$raw'.toLowerCase()) {
        'requested' => RentalStatus.requested,
        'awaitingowner' || 'awaiting_owner' => RentalStatus.awaitingOwner,
        'accepted' || 'approved' => RentalStatus.accepted,
        'active' => RentalStatus.active,
        'returned' => RentalStatus.returned,
        'completed' => RentalStatus.completed,
        'declined' => RentalStatus.declined,
        'cancelled' || 'canceled' => RentalStatus.cancelled,
        // Anything else in the old vocabulary was "asked for, not yet decided".
        _ => RentalStatus.requested,
      };
}