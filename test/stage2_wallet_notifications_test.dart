import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/data/db_service.dart';
import 'package:surgo/repositories/backend.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/screens/home_screen.dart';
import 'package:surgo/screens/notifications_screen.dart';
import 'package:surgo/screens/rider_home_screen.dart';
import 'package:surgo/screens/wallet_screen.dart';
import 'package:surgo/services/money.dart';
import 'package:surgo/state/app_state.dart';
import 'package:surgo/theme/app_colors.dart';
import 'package:surgo/widgets/surfaces.dart';

/// Stage 2 proof for the wallet amount and the unread badges: what those
/// widgets show comes from whichever registry the build installed, and a read
/// that cannot be answered is shown as a failure or as no badge at all rather
/// than as a seeded number.
///
/// [AppState] and [DbService] are singletons shared with the rest of the suite,
/// so the money and the notification lists are snapshotted and put back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;
  final db = DbService.instance;

  /// Drains the microtask the cache notifies on. A delayed future would not
  /// fire inside a widget test, where the clock is faked.
  Future<void> settle() async {
    for (var turn = 0; turn < 12; turn++) {
      await Future<void>.value();
    }
  }

  /// Installs [registry] and drops every cached answer, so no test inherits
  /// another test's read.
  Future<void> use(RepositoryRegistry registry) async {
    state.configureRepositories(registry);
    state.cache.restart();
    await settle();
  }

  late int passengerWallet;
  late int earnerWallet;
  late List<WalletTransaction> passengerTransactions;
  late List<NotificationItem> passengerNotifications;
  late List<NotificationItem> earnerNotifications;

  /// The seed notification objects are shared with every other test in the
  /// suite and marking one read mutates it in place, so the flags are
  /// restored alongside the lists.
  List<bool> readFlags(List<NotificationItem> items) =>
      items.map((n) => n.read).toList();

  void restoreReadFlags(List<NotificationItem> items, List<bool> flags) {
    for (var i = 0; i < items.length && i < flags.length; i++) {
      items[i].read = flags[i];
    }
  }

  late List<bool> passengerReadFlags;
  late List<bool> earnerReadFlags;

  setUpAll(() async => db.load());

  setUp(() {
    passengerWallet = db.passengerWalletBalance;
    earnerWallet = db.earnerWalletBalance;
    passengerTransactions = List.of(db.passengerTransactions);
    passengerNotifications = List.of(db.passengerNotifications);
    earnerNotifications = List.of(db.earnerNotifications);
    passengerReadFlags = readFlags(db.passengerNotifications);
    earnerReadFlags = readFlags(db.earnerNotifications);
  });

  tearDown(() async {
    db.passengerWalletBalance = passengerWallet;
    db.earnerWalletBalance = earnerWallet;
    db.passengerTransactions
      ..clear()
      ..addAll(passengerTransactions);
    db.passengerNotifications
      ..clear()
      ..addAll(passengerNotifications);
    db.earnerNotifications
      ..clear()
      ..addAll(earnerNotifications);
    restoreReadFlags(db.passengerNotifications, passengerReadFlags);
    restoreReadFlags(db.earnerNotifications, earnerReadFlags);
    await use(RepositoryRegistry.mock(db));
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle();
    await tester.pump();
  }

  /// Lets a settled read reach the widget after a state change.
  Future<void> land(WidgetTester tester) async {
    await tester.pump();
    await settle();
    await tester.pump();
  }

  /// The unread badge is the only text inside these headers' `Positioned`, so
  /// looking there keeps a number from elsewhere on the screen from matching.
  Finder badge(String value) =>
      find.descendant(of: find.byType(Positioned), matching: find.text(value));

  int unread(List<NotificationItem> items) =>
      items.where((n) => !n.read).length;

  /// The unread dot each feed card draws: a primary-coloured circle.
  Finder unreadDots() => find.byWidgetPredicate((widget) {
        if (widget is! Container) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.shape == BoxShape.circle &&
            decoration.color == AppColors.primary;
      });

  /// Marks the whole feed unread.
  ///
  /// The seed's own read flags are shared singletons that other tests flip, so
  /// a badge test states what it needs instead of trusting them.
  void makeUnread(List<NotificationItem> items) {
    expect(items, isNotEmpty, reason: 'the seed must ship a notification feed');
    for (final n in items) {
      n.read = false;
    }
  }

  group('wallet balance', () {
    testWidgets('a seeded build shows the wallet the app actually writes to',
        (tester) async {
      await open(tester, const WalletScreen());

      expect(find.text(Money.format(db.passengerWalletBalance)), findsOneWidget);
      expect(find.text('—'), findsNothing,
          reason: 'the read has landed, so the placeholder amount is gone');

      state.topUpPassengerWallet(Money.pesos(100), 'GCash');
      await land(tester);

      expect(find.text(Money.format(passengerWallet + Money.pesos(100))),
          findsOneWidget,
          reason: 'the read follows the write, not the seed table');
    });

    testWidgets('a payout wallet reads the earner account, not the passenger',
        (tester) async {
      await open(tester, const WalletScreen(isRider: true));

      expect(find.text('Available for payout'), findsOneWidget);
      expect(find.text(Money.format(earnerWallet)), findsOneWidget);
      expect(find.text(Money.format(passengerWallet)), findsNothing);
    });

    testWidgets('a Supabase build shows the account row it was given',
        (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'wallet_accounts': [
          {
            'id': 'wa-1',
            'profile_id': 'auth-uuid-1',
            'account_type': 'passenger',
            'balance_centavos': 250000,
            'is_active': true,
          },
        ],
      })));

      await open(tester, const WalletScreen());

      expect(find.text('₱2,500.00'), findsOneWidget);
      expect(find.text(Money.format(passengerWallet)), findsNothing,
          reason: 'a production read must not show the seeded balance');
    });

    testWidgets('an unreachable read fails visibly and recovers on retry',
        (tester) async {
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester, const WalletScreen());

      expect(find.text('The data service is unavailable right now.'),
          findsNWidgets(2),
          reason: 'the balance card and the history list each report it');
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Try again'), findsNWidgets(2));
      expect(find.text(Money.format(passengerWallet)), findsNothing);

      // Swapping the registry without restarting keeps the failure on screen,
      // so the retry button is what re-reads each slot.
      state.configureRepositories(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'wallet_accounts': [
          {
            'id': 'wa-1',
            'profile_id': 'auth-uuid-1',
            'account_type': 'passenger',
            'balance_centavos': 123400,
            'is_active': true,
          },
        ],
      })));
      // Each read retries its own slot, so both controls have to be used.
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('Try again').first);
        await land(tester);
      }

      expect(find.text('₱1,234.00'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('No transactions yet'), findsOneWidget);
    });

    testWidgets('a wallet that is closed reads as zero, not as a guess',
        (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'wallet_accounts': [
          {
            'id': 'wa-1',
            'profile_id': 'auth-uuid-1',
            'account_type': 'passenger',
            'balance_centavos': 900000,
            'is_active': false,
          },
        ],
      })));

      await open(tester, const WalletScreen());

      expect(find.text('₱0.00'), findsOneWidget);
    });
  });

  group('wallet history', () {
    testWidgets('a seeded build lists the ledger the app writes to',
        (tester) async {
      await open(tester, const WalletScreen());

      final seeded = db.passengerTransactions.length;
      expect(find.byType(SbTintedCard), findsNWidgets(seeded));
      expect(find.text(db.passengerTransactions.first.title), findsOneWidget);

      state.topUpPassengerWallet(Money.pesos(100), 'GCash');
      await land(tester);

      expect(find.byType(SbTintedCard), findsNWidgets(seeded + 1),
          reason: 'the read follows the write, not the seed table');
      expect(find.text('Wallet Top-up via GCash'), findsAtLeastNWidgets(1));
    });

    testWidgets('a Supabase build lists the ledger rows it was given',
        (tester) async {
      final now = DateTime.now().toUtc().toIso8601String();
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'wallet_accounts': [
          {
            'id': 'wa-1',
            'profile_id': 'auth-uuid-1',
            'account_type': 'passenger',
            'balance_centavos': 250000,
            'is_active': true,
          },
        ],
        'wallet_transactions': [
          {
            'id': 'wt-1',
            'wallet_account_id': 'wa-1',
            'transaction_type': 'top_up',
            'direction': 'credit',
            'amount_centavos': 250000,
            'balance_after_centavos': 250000,
            'description': 'GCash top-up',
            'created_at': now,
          },
        ],
      })));

      await open(tester, const WalletScreen());

      expect(find.text('GCash top-up'), findsOneWidget);
      expect(find.text('+₱2,500.00'), findsOneWidget);
      // wallet_transactions has no status column, so the type says what the
      // row was.
      expect(find.textContaining(' · Top-up'), findsOneWidget);
      expect(find.text(db.passengerTransactions.first.title), findsNothing,
          reason: 'a production read must not show the seeded ledger');
    });

    testWidgets('a wallet with no entries says so', (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'wallet_accounts': [
          {
            'id': 'wa-1',
            'profile_id': 'auth-uuid-1',
            'account_type': 'passenger',
            'balance_centavos': 250000,
            'is_active': true,
          },
        ],
      })));

      await open(tester, const WalletScreen());

      expect(find.text('No transactions yet'), findsOneWidget);
      expect(find.text(db.passengerTransactions.first.title), findsNothing);
    });
  });

  group('unread badge', () {
    testWidgets('the passenger home counts the passenger feed', (tester) async {
      makeUnread(db.passengerNotifications);
      await open(tester, const HomeScreen(embedded: false));

      expect(badge('${unread(db.passengerNotifications)}'), findsOneWidget);

      state.clearNotifications();
      await land(tester);

      expect(badge('0'), findsNothing,
          reason: 'a zero count shows no badge at all');
    });

    testWidgets('the rider home counts the earner feed, not the passenger one',
        (tester) async {
      makeUnread(db.earnerNotifications);
      state.clearNotifications();
      expect(unread(db.passengerNotifications), 0);

      await open(tester, const RiderHomeScreen(embedded: false));

      expect(badge('${unread(earnerNotifications)}'), findsOneWidget);
    });

    testWidgets('a Supabase build counts the rows RLS returned', (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'notifications': [
          for (var i = 1; i <= 7; i++) {'id': 'n$i'},
        ],
      })));

      await open(tester, const HomeScreen(embedded: false));

      expect(badge('7'), findsOneWidget);
    });

    testWidgets('an unreachable feed shows no badge instead of a seeded count',
        (tester) async {
      makeUnread(db.passengerNotifications);
      expect(unread(passengerNotifications), greaterThan(0),
          reason: 'the seed must have something unread to hide');
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester, const HomeScreen(embedded: false));

      expect(badge('${unread(passengerNotifications)}'), findsNothing);
    });
  });

  group('notification feed', () {
    testWidgets('a seeded build lists the feed the repository returns',
        (tester) async {
      await open(tester, const NotificationsScreen());

      expect(find.byType(SbTintedCard),
          findsNWidgets(db.passengerNotifications.length));
      expect(find.text(db.passengerNotifications.first.title), findsOneWidget);
    });

    testWidgets('the rider flag reads the earner feed instead', (tester) async {
      await open(tester, const NotificationsScreen(isRider: true));

      expect(find.byType(SbTintedCard),
          findsNWidgets(db.earnerNotifications.length));
    });

    testWidgets('a card read by the passenger clears its own dot',
        (tester) async {
      makeUnread(db.passengerNotifications);
      // The seed was edited behind the cache's back, so the settled feed read
      // has to be dropped before the screen is opened.
      await use(RepositoryRegistry.mock(db));
      await open(tester, const NotificationsScreen());

      expect(unreadDots(), findsNWidgets(unread(db.passengerNotifications)));

      await tester.tap(find.byType(SbTintedCard).first);
      await land(tester);

      expect(unreadDots(), findsNWidgets(unread(db.passengerNotifications)));
      expect(unread(db.passengerNotifications),
          lessThan(passengerNotifications.length));

      await tester.tap(find.text('Mark all read'));
      await land(tester);

      expect(unreadDots(), findsNothing);
    });

    testWidgets('a Supabase build lists the rows it was given, not the seed',
        (tester) async {
      final now = DateTime.now().toUtc().toIso8601String();
      await use(RepositoryRegistry.supabase(_FixedBackend(rowsByTable: {
        'notifications': [
          {
            'id': 'n-1',
            'notification_type': 'ride',
            'title': 'Rider assigned',
            'body': 'Your rider has accepted the trip.',
            'created_at': now,
          },
          {
            'id': 'n-2',
            'notification_type': 'promo',
            'title': 'Weekend rides are half price',
            'body': 'Book before Sunday to save.',
            'read_at': now,
            'created_at': now,
          },
        ],
      })));

      await open(tester, const NotificationsScreen());

      expect(find.text('Rider assigned'), findsOneWidget);
      expect(find.text('Weekend rides are half price'), findsOneWidget);
      expect(find.text(db.passengerNotifications.first.title), findsNothing,
          reason: 'a production read must not show the seeded feed');
      // read_at is the database truth, so only the unread row keeps its dot.
      expect(unreadDots(), findsOneWidget);
      expect(find.text('Just now'), findsNWidgets(2));
    });

    testWidgets('a feed with no rows says so', (tester) async {
      await use(RepositoryRegistry.supabase(_FixedBackend()));

      await open(tester, const NotificationsScreen());

      expect(find.text('No notifications yet'), findsOneWidget);
      expect(find.byType(SbTintedCard), findsNothing);
    });

    testWidgets('an unreachable feed fails visibly instead of showing the seed',
        (tester) async {
      expect(db.passengerNotifications, isNotEmpty);
      await use(RepositoryRegistry.supabase(const UnreachableBackend()));

      await open(tester, const NotificationsScreen());

      expect(find.text('The data service is unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(SbTintedCard), findsNothing);
    });
  });
}

/// A backend that answers from fixed rows, so a screen test can show which
/// source its numbers came from.
class _FixedBackend implements SurgoBackend {
  _FixedBackend({this.rowsByTable = const {}});

  final Map<String, List<Map<String, dynamic>>> rowsByTable;

  @override
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async {
    final found = rowsByTable[table] ?? const [];
    return limit == null ? found : found.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    final found = rowsByTable[table] ?? const [];
    if (found.isEmpty) return null;
    for (final row in found) {
      if (eq.entries.every((where) => row[where.key] == where.value)) {
        return row;
      }
    }
    return found.first;
  }
}
