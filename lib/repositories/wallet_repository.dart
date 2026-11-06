import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// Wallet balances, transaction history and settled service money.
///
/// Payout requests, top-ups and any other write are deliberately absent: the
/// deployed schema grants `authenticated` SELECT only, so there is nothing for
/// a client write to land on until reviewed RPCs exist.
abstract interface class WalletRepository {
  Future<List<WalletAccountRecord>> fetchWalletAccounts(String profileId);

  /// The spendable balance across this profile's active wallets.
  Future<int> fetchBalanceCentavos(String profileId);

  Future<List<WalletEntryRecord>> fetchTransactions(
    String profileId, {
    int? limit,
  });

  /// Settlement rows where this profile is either the customer or the provider.
  Future<List<ServiceTransactionRecord>> fetchSettlements(String profileId);

  Future<List<CashFeeRemittanceRecord>> fetchFeeRemittances(
      String providerProfileId);
}

class SupabaseWalletRepository implements WalletRepository {
  SupabaseWalletRepository(SurgoBackend backend) : _backend = backend;

  final SurgoBackend _backend;

  @override
  Future<List<WalletAccountRecord>> fetchWalletAccounts(
      String profileId) async {
    final rows = await _backend.rows(
      table: 'wallet_accounts',
      columns: 'id, profile_id, account_type, currency, balance_centavos, '
          'is_active',
      eq: {'profile_id': profileId},
    );
    return [for (final row in rows) WalletAccountRecord.fromRow(row)];
  }

  @override
  Future<int> fetchBalanceCentavos(String profileId) async {
    final accounts = await fetchWalletAccounts(profileId);
    return accounts
        .where((account) => account.isActive)
        .fold<int>(0, (sum, account) => sum + account.balanceCentavos);
  }

  @override
  Future<List<WalletEntryRecord>> fetchTransactions(
    String profileId, {
    int? limit,
  }) async {
    final accounts = await fetchWalletAccounts(profileId);
    if (accounts.isEmpty) return const [];
    final rows = await _backend.rows(
      table: 'wallet_transactions',
      columns: 'id, wallet_account_id, transaction_type, direction, '
          'amount_centavos, balance_after_centavos, service_transaction_id, '
          'external_reference, description, created_at',
      whereIn: {
        'wallet_account_id': [for (final a in accounts) a.id],
      },
      orderBy: 'created_at',
      limit: limit,
    );
    return [for (final row in rows) WalletEntryRecord.fromRow(row)];
  }

  @override
  Future<List<ServiceTransactionRecord>> fetchSettlements(
      String profileId) async {
    // RLS already limits these rows to the participants, so the two reads are
    // merged and de-duplicated here instead of building an `or=` filter.
    final rows = <String, Map<String, dynamic>>{};
    for (final column in const ['customer_id', 'provider_id']) {
      final page = await _backend.rows(
        table: 'service_transactions',
        columns: _settlementColumns,
        eq: {column: profileId},
        orderBy: 'created_at',
      );
      for (final row in page) {
        final id = row['id'];
        if (id is String) rows[id] = row;
      }
    }
    final merged = rows.values.toList()
      ..sort((a, b) {
        final left = a['created_at'];
        final right = b['created_at'];
        if (left is! String || right is! String) return 0;
        return right.compareTo(left);
      });
    return [for (final row in merged) ServiceTransactionRecord.fromRow(row)];
  }

  @override
  Future<List<CashFeeRemittanceRecord>> fetchFeeRemittances(
      String providerProfileId) async {
    final rows = await _backend.rows(
      table: 'cash_fee_remittances',
      columns: 'id, provider_id, service_transaction_id, currency, '
          'amount_centavos, status, due_at, remitted_at, reference_number, '
          'notes, created_at',
      eq: {'provider_id': providerProfileId},
      orderBy: 'due_at',
      ascending: true,
    );
    return [for (final row in rows) CashFeeRemittanceRecord.fromRow(row)];
  }
}

const String _settlementColumns =
    'id, service_type, ride_id, rental_id, service_request_id, customer_id, '
    'provider_id, currency, fare_centavos, platform_fee_centavos, '
    'customer_pays_centavos, provider_payout_centavos, '
    'platform_revenue_centavos, payment_method, status, settled_at, created_at';

/// Reads the seeded per-profile wallets.
class MockWalletRepository implements WalletRepository {
  MockWalletRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  @override
  Future<List<WalletAccountRecord>> fetchWalletAccounts(
      String profileId) async {
    final balance = _balanceFor(profileId);
    if (balance == null) return const [];
    return [
      WalletAccountRecord(
        id: 'mock-wallet-$profileId',
        profileId: profileId,
        accountType: _accountTypeFor(profileId),
        balanceCentavos: balance,
      ),
    ];
  }

  @override
  Future<int> fetchBalanceCentavos(String profileId) async =>
      _balanceFor(profileId) ?? 0;

  @override
  Future<List<WalletEntryRecord>> fetchTransactions(
    String profileId, {
    int? limit,
  }) async {
    final transactions = _transactionsFor(profileId);
    final records = [
      for (final item in transactions) _toRecord(profileId, item)
    ];
    return limit == null ? records : records.take(limit).toList();
  }

  @override
  Future<List<ServiceTransactionRecord>> fetchSettlements(
      String profileId) async {
    // The seed has no settlement rows; its money totals are derived in memory
    // by AppState and FeeCalculator instead.
    return const [];
  }

  @override
  Future<List<CashFeeRemittanceRecord>> fetchFeeRemittances(
      String providerProfileId) async {
    throw RepositoryFailure.unsupported(
      'Cash platform-fee remittances are an admin-side concern and have no '
      'seeded equivalent.',
    );
  }

  int? _balanceFor(String profileId) {
    // The signed-in role's balance is the field the app's money paths write to,
    // so it is answered first: `walletBalanceByUser` keeps the amounts the seed
    // loaded and a top-up or payout never updates it, which would otherwise
    // make a wallet screen show yesterday's number.
    if (profileId == _db.passenger.id) return _db.passengerWalletBalance;
    if (profileId == _db.earner.id) return _db.earnerWalletBalance;
    if (profileId == _db.vehicleOwner.id) return _db.ownerWalletBalance;
    return _db.walletBalanceByUser[profileId];
  }

  List<WalletTransaction> _transactionsFor(String profileId) {
    final stored = _db.walletTransactionsByUser[profileId];
    if (stored != null) return stored;
    if (profileId == _db.passenger.id) return _db.passengerTransactions;
    if (profileId == _db.earner.id) return _db.earnerTransactions;
    if (profileId == _db.vehicleOwner.id) return _db.ownerTransactions;
    return const [];
  }

  String _accountTypeFor(String profileId) {
    if (_db.earners.containsKey(profileId) || profileId == _db.earner.id) {
      return 'earner';
    }
    if (_db.owners.containsKey(profileId) || profileId == _db.vehicleOwner.id) {
      return 'provider';
    }
    return 'passenger';
  }

  WalletEntryRecord _toRecord(String profileId, WalletTransaction item) =>
      WalletEntryRecord(
        id: item.id,
        walletAccountId: 'mock-wallet-$profileId',
        // The seed classifies an entry with its own vocabulary (`topup`,
        // `payout`, `credit`, `debit`, plus a `kind` like `bonus`). Direction is
        // the part the ledger semantics depend on, so it is derived here.
        type: item.kind ?? item.type,
        direction: item.isPositive ? 'credit' : 'debit',
        amountCentavos: item.amount,
        description: item.title,
        createdAt: item.createdAt,
      );
}
