import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/auth/mock_auth_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/data/models.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/active_rental_screen.dart';
import 'package:surgo/screens/home_screen.dart';
import 'package:surgo/services/fee_calculator.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/state/rental_status.dart';
import 'package:surgo/widgets/common.dart';
import 'package:surgo/widgets/surgo_map.dart';

class _HostedAuth extends MockAuthRepository {
  @override
  bool get isMock => false;

  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();
}

class _Navigation extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

RentalBooking _booking({
  String id = 'tracked-demo',
  RentalStatus status = RentalStatus.returned,
  String vehicleName = 'Tracked motorcycle',
  int fare = 23456,
}) => RentalBooking(
  id: id,
  vehicleName: vehicleName,
  vehicleType: 'Motorcycle',
  icon: Icons.two_wheeler,
  ownerName: 'Tracked Owner',
  ownerInitials: 'TO',
  pickupLabel: '12 Nov 2026',
  returnLabel: '14 Nov 2026',
  pickupDate: DateTime(2026, 11, 12),
  returnDate: DateTime(2026, 11, 14),
  days: 2,
  totalFare: fare,
  status: status,
  requestedAt: DateTime(2026, 11, 11),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = AppState.instance;
  final db = DbService.instance;
  final ledger = PlatformLedger.instance;
  late _Navigation navigation;
  late List<RentalHistoryItem> history;
  late int wallet;
  late int today;
  late int week;
  late int month;

  setUpAll(() async => db.load());

  setUp(() {
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock(db));
    state.currentAccount = db.accounts.first;
    state.identity = null;
    state.authStatus = AuthStatus.signedIn;
    state.mode = UserMode.passenger;
    state.activeRentalBooking = null;
    state.lastRentalBreakdown = null;
    history = List.of(db.rentalHistory);
    wallet = db.ownerWalletBalance;
    today = db.ownerEarningsToday;
    week = db.ownerEarningsWeek;
    month = db.ownerEarningsMonth;
    navigation = _Navigation();
    ledger.reset();
  });

  tearDown(() {
    state.cancelRentalBooking();
    state.lastRentalBreakdown = null;
    state.configureAuth(MockAuthRepository());
    state.configureRepositories(RepositoryRegistry.mock(db));
    state.currentAccount = null;
    state.identity = null;
    state.authStatus = AuthStatus.signedOut;
    state.mode = UserMode.passenger;
    db.rentalHistory
      ..clear()
      ..addAll(history);
    db.ownerWalletBalance = wallet;
    db.ownerEarningsToday = today;
    db.ownerEarningsWeek = week;
    db.ownerEarningsMonth = month;
    ledger.reset();
  });

  Future<void> frame(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> open(
    WidgetTester tester, {
    Widget screen = const ActiveRentalScreen(),
    Object? argument,
    bool root = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [navigation],
        home: root
            ? screen
            : Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        settings: RouteSettings(arguments: argument),
                        builder: (_) => screen,
                      ),
                    ),
                    child: const Text('Open rental'),
                  ),
                ),
              ),
        routes: {
          '/home': (_) => const Scaffold(body: Text('Home destination')),
          '/owner': (_) => const Scaffold(body: Text('Owner Home destination')),
        },
      ),
    );
    if (!root) await tester.tap(find.text('Open rental'));
    await frame(tester);
  }

  void receiptFor(RentalBooking booking) {
    final split = FeeCalculator.breakdownFor(
      ServiceType.rental,
      booking.totalFare,
    );
    expect(find.text('Rental receipt'), findsOneWidget);
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.text(booking.vehicleName), findsOneWidget);
    expect(find.text('Owned by ${booking.ownerName}'), findsOneWidget);
    expect(find.text(booking.pickupLabel), findsOneWidget);
    expect(find.text(booking.returnLabel), findsOneWidget);
    for (final row in <(String, int)>[
      ('Owner receives', split.providerGets),
      ('SurGo commission', split.surgoKeeps),
      ('You paid · Cash', split.customerPays),
    ]) {
      final moneyRow = find
          .ancestor(of: find.text(row.$1), matching: find.byType(Row))
          .first;
      expect(
        find.descendant(
          of: moneyRow,
          matching: find.text(Money.format(row.$2)),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('SurGo platform fee'), findsNothing);
    expect(find.text('Complete rental'), findsNothing);
    expect(find.text('Cancel Request'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  }

  void noSettlement() {
    expect(db.ownerWalletBalance, wallet);
    expect(db.ownerEarningsToday, today);
    expect(db.ownerEarningsWeek, week);
    expect(db.ownerEarningsMonth, month);
    expect(ledger.transactionCount, 0);
    expect(find.text('Rental receipt'), findsNothing);
    expect(find.text('Owner receives'), findsNothing);
    expect(find.text('SurGo commission'), findsNothing);
    expect(find.text('You paid · Cash'), findsNothing);
  }

  for (final hostedIdentity in [false, true]) {
    testWidgets('Home reopens the exact demo rental (hosted=$hostedIdentity)', (
      tester,
    ) async {
      if (hostedIdentity) state.configureAuth(_HostedAuth());
      state.cache.restart();
      final booking = _booking(status: RentalStatus.requested);
      state.activeRentalBooking = booking;
      final semantics = tester.ensureSemantics();
      try {
        await open(
          tester,
          root: true,
          screen: const HomeScreen(embedded: false),
        );
        final card = find.bySemanticsLabel(
          'Current rental · Tracked motorcycle · Request sent',
        );
        expect(card, findsOneWidget);
        await tester.tap(card);
      } finally {
        semantics.dispose();
      }
      await frame(tester);
      expect(find.text('Your Rental'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ActiveRentalScreen),
          matching: find.text(booking.vehicleName),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ActiveRentalScreen),
          matching: find.text('REQUESTED'),
        ),
        findsOneWidget,
      );
      expect(state.activeRentalBooking, same(booking));
      expect(tester.takeException(), isNull);
    });
  }

  for (final root in [false, true]) {
    testWidgets('empty demo stays visible with safe Home (root=$root)', (
      tester,
    ) async {
      // A global receipt must never fill an empty rental screen.
      state.lastRentalBreakdown = FeeCalculator.breakdownFor(
        ServiceType.rental,
        99000,
      );
      await open(tester, root: root);
      expect(find.text('No current rental request.'), findsOneWidget);
      expect(navigation.pops, 0);
      noSettlement();
      await tester.tap(find.text('Home'));
      await frame(tester);
      expect(find.text('Home destination'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'simulated approval, pickup, return and retained cash receipt settle once',
    (tester) async {
      final booking = state.requestRental(
        vehicleId: null,
        vehicleName: 'Tracked motorcycle',
        vehicleType: 'Motorcycle',
        icon: Icons.two_wheeler,
        ownerName: 'Tracked Owner',
        ownerInitials: 'TO',
        pickupLabel: '12 Nov 2026',
        returnLabel: '14 Nov 2026',
        pickupDate: DateTime(2026, 11, 12),
        returnDate: DateTime(2026, 11, 14),
        days: 2,
        totalFare: 23456,
      );
      await open(tester);
      expect(find.text('REQUESTED'), findsOneWidget);
      expect(find.text('Waiting for owner approval…'), findsOneWidget);
      expect(find.textContaining('simulated after 10 seconds'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.byType(SurgoMap), findsOneWidget);
      noSettlement();
      await tester.pump(const Duration(seconds: 9));
      expect(booking.status, RentalStatus.requested);
      await tester.pump(const Duration(seconds: 1));
      await frame(tester);
      expect(booking.status, RentalStatus.accepted);
      expect(find.text('Owner approved'), findsOneWidget);
      expect(find.textContaining('not been picked up yet'), findsOneWidget);
      expect(find.text('Rental is active'), findsNothing);
      final pickup = tester
          .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
          .onPressed!;
      pickup();
      pickup(); // A stale tap cannot advance two different lifecycle steps.
      await frame(tester);
      expect(booking.status, RentalStatus.active);
      expect(find.text('ACTIVE'), findsOneWidget);
      noSettlement();
      await tester.tap(find.text('Return the vehicle'));
      await frame(tester);
      expect(booking.status, RentalStatus.returned);
      expect(find.text('Vehicle returned'), findsOneWidget);
      expect(find.textContaining('to settle this demo rental'), findsOneWidget);
      noSettlement();
      final complete = tester
          .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
          .onPressed!;
      complete();
      complete();
      state.completeActiveRental();
      await frame(tester);
      expect(booking.status, RentalStatus.completed);
      expect(state.activeRentalBooking, isNull);
      expect(navigation.pops, 0);
      expect(find.text('Open rental'), findsNothing);
      receiptFor(booking);
      final split = FeeCalculator.breakdownFor(
        ServiceType.rental,
        booking.totalFare,
      );
      expect(split.customerPays, 23456);
      expect(split.providerGets, 21110);
      expect(split.surgoKeeps, 2346);
      expect(split.basis, FeeBasis.percentageCommission);
      expect(db.ownerWalletBalance, wallet + split.providerGets);
      expect(db.ownerEarningsToday, today + split.providerGets);
      expect(ledger.transactionCount, 1);
      expect(ledger.entries.single.gross, booking.totalFare);
      expect(ledger.entries.single.providerGets, split.providerGets);
      expect(ledger.entries.single.surgoKeeps, split.surgoKeeps);
      expect(find.byType(SurgoMap), findsOneWidget);
      await tester.tap(find.text('Home'));
      await frame(tester);
      expect(find.text('Home destination'), findsOneWidget);
    },
  );

  testWidgets(
    'external settlement retains exact booking despite another completed rental',
    (tester) async {
      final tracked = _booking();
      state.activeRentalBooking = tracked;
      await open(tester);
      final staleComplete = tester
          .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
          .onPressed!;
      state.completeActiveRental();
      // No intervening frame: the last global split already belongs to someone else.
      final other = _booking(
        id: 'other',
        vehicleName: 'Unrelated van',
        fare: 99999,
      );
      state.activeRentalBooking = other;
      state.notifyListeners();
      staleComplete();
      expect(other.status, RentalStatus.returned);
      expect(ledger.transactionCount, 1);
      state.completeActiveRental();
      await frame(tester);
      receiptFor(tracked);
      expect(find.text('Unrelated van'), findsNothing);
      expect(state.lastRentalBreakdown!.customerPays, other.totalFare);
      expect(navigation.pops, 0);
    },
  );

  testWidgets(
    'same-id replacement cannot substitute or receive a stale settlement',
    (tester) async {
      final tracked = _booking();
      state.activeRentalBooking = tracked;
      await open(tester);
      final staleComplete = tester
          .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
          .onPressed!;
      final replacement = _booking(
        vehicleName: 'Same-id impostor',
        fare: 99999,
      );
      state.activeRentalBooking = replacement;
      state.notifyListeners();
      staleComplete();
      await frame(tester);
      expect(tracked.status, RentalStatus.returned);
      expect(replacement.status, RentalStatus.returned);
      expect(find.text('This rental is no longer available.'), findsOneWidget);
      expect(find.text('Same-id impostor'), findsNothing);
      expect(find.text('Tracked motorcycle'), findsNothing);
      noSettlement();
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets(
    'demo cancellation stays visible without payout or completed claims',
    (tester) async {
      final booking = state.requestRental(
        vehicleId: null,
        vehicleName: 'Tracked motorcycle',
        vehicleType: 'Motorcycle',
        icon: Icons.two_wheeler,
        ownerName: 'Tracked Owner',
        ownerInitials: 'TO',
        pickupLabel: '12 Nov 2026',
        returnLabel: '14 Nov 2026',
        pickupDate: DateTime(2026, 11, 12),
        returnDate: DateTime(2026, 11, 14),
        days: 2,
        totalFare: 23456,
      );
      state.lastRentalBreakdown = FeeCalculator.breakdownFor(
        ServiceType.rental,
        99999,
      );
      await open(tester);
      await tester.tap(find.text('Cancel Request'));
      await frame(tester);
      await tester.pump(const Duration(seconds: 11));
      expect(booking.status, RentalStatus.cancelled);
      expect(state.activeRentalBooking, isNull);
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(
        find.textContaining('No payment or owner payout was recorded'),
        findsOneWidget,
      );
      expect(find.text('Tracked motorcycle'), findsOneWidget);
      expect(find.text('COMPLETED'), findsNothing);
      expect(find.text('Cancel Request'), findsNothing);
      expect(find.byType(SbPrimaryButton), findsNothing);
      expect(navigation.pops, 0);
      noSettlement();
      await tester.tap(find.text('Home'));
      await frame(tester);
      expect(find.text('Home destination'), findsOneWidget);
    },
  );

  testWidgets(
    'explicit demo booking and id cannot fall back to unrelated active request',
    (tester) async {
      final tracked = _booking(status: RentalStatus.completed);
      state.activeRentalBooking = _booking(
        id: 'other',
        vehicleName: 'Unrelated van',
      );
      await open(
        tester,
        argument: tracked,
        screen: ActiveRentalScreen(rentalId: tracked.id),
      );
      receiptFor(tracked);
      expect(find.text('Unrelated van'), findsNothing);
    },
  );

  testWidgets(
    'missing explicit id stays empty instead of following a new booking',
    (tester) async {
      state.activeRentalBooking = _booking(
        id: 'other',
        vehicleName: 'Unrelated van',
      );
      await open(tester, screen: const ActiveRentalScreen(rentalId: 'missing'));
      expect(find.text('This rental is no longer available.'), findsOneWidget);
      state.activeRentalBooking = _booking(
        id: 'missing',
        vehicleName: 'Later van',
      );
      state.notifyListeners();
      await frame(tester);
      expect(find.text('This rental is no longer available.'), findsOneWidget);
      expect(find.text('Later van'), findsNothing);
      noSettlement();
    },
  );

  for (final binding in ['account', 'identity', 'registry', 'sign-out']) {
    testWidgets(
      '$binding change retires retained receipt even if restored before next frame',
      (tester) async {
        final tracked = _booking();
        state.activeRentalBooking = tracked;
        await open(tester);
        state.completeActiveRental();
        await frame(tester);
        receiptFor(tracked);
        final originalAccount = state.currentAccount;
        final originalRegistry = state.repositories;
        switch (binding) {
          case 'account':
            state.currentAccount = db.accounts.firstWhere(
              (account) => account.id != originalAccount!.id,
            );
            state.notifyListeners();
            state.currentAccount = originalAccount;
          case 'identity':
            state.identity = const SurgoIdentity(
              userId: 'different-auth-user',
              capabilities: {},
              eligibleCapabilities: {},
              roles: {},
              providers: {},
            );
            state.notifyListeners();
            state.identity = null;
          case 'registry':
            state.configureRepositories(RepositoryRegistry.mock(db));
            state.notifyListeners();
            state.configureRepositories(originalRegistry);
          case 'sign-out':
            await state.logout();
            state.currentAccount = originalAccount;
            state.authStatus = AuthStatus.signedIn;
        }
        state.notifyListeners();
        await frame(tester);
        expect(find.textContaining('Your session changed.'), findsOneWidget);
        expect(find.text('Tracked motorcycle'), findsNothing);
        expect(find.text('Tracked Owner'), findsNothing);
        expect(find.text('Rental receipt'), findsNothing);
        expect(find.text('You paid · Cash'), findsNothing);
        expect(find.byType(SbPrimaryButton), findsNothing);
        expect(ledger.transactionCount, 1);
        await tester.tap(find.text('Home'));
        await frame(tester);
        expect(find.text('Home destination'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'session-changed stale completion cannot pay a different account',
    (tester) async {
      state.activeRentalBooking = _booking();
      await open(tester);
      final complete = tester
          .widget<SbPrimaryButton>(find.byType(SbPrimaryButton))
          .onPressed!;
      state.currentAccount = db.accounts.firstWhere(
        (account) => account.id != state.currentAccount!.id,
      );
      // Even without a notification, action callbacks revalidate their binding.
      complete();
      state.notifyListeners();
      await frame(tester);
      noSettlement();
      expect(find.textContaining('Your session changed.'), findsOneWidget);
    },
  );

  testWidgets(
    'hosted identity on seeded repositories still shows simulated demo approval',
    (tester) async {
      state.configureAuth(_HostedAuth());
      state.currentAccount = state.currentAccount!.copyWith(
        authUserId: 'hosted-seeded',
      );
      state.identity = const SurgoIdentity(
        userId: 'hosted-seeded',
        capabilities: {CapabilityType.passenger},
        eligibleCapabilities: {},
        roles: {'passenger'},
        providers: {'phone'},
      );
      state.activeRentalBooking = _booking(status: RentalStatus.awaitingOwner);
      await open(tester);
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.textContaining('simulated after 10 seconds'), findsOneWidget);
      expect(find.byType(SurgoMap), findsOneWidget);
      state.acceptRentalRequest();
      await frame(tester);
      expect(find.text('Owner approved'), findsOneWidget);
      noSettlement();
    },
  );
}
