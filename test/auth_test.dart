import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// Exercises the local mock sign-in: matching, role gating, identity swap and
/// registration. The seed is a plaintext prototype (see accounts.json), so the
/// tests pin the contract the screens rely on rather than any real security.
void main() {
  late AppState state;

  // DbService loads the seed through rootBundle, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    state = AppState.instance;
    await state.init();
  });

  setUp(() => state.logout());

  test('signs in with a seeded phone and password', () {
    expect(state.login('+63 917 512 4809', 'surgo123'), AuthResult.ok);
    expect(state.isSignedIn, isTrue);
    expect(state.currentAccount?.id, 'ACC001');
  });

  test('signs in with email as well as phone', () {
    expect(state.login('grace.villaflor@email.com', 'surgo123'), AuthResult.ok);
    expect(state.currentAccount?.id, 'ACC002');
  });

  test('reports an unknown account rather than guessing', () {
    expect(state.login('nobody@nowhere.com', 'surgo123'),
        AuthResult.unknownAccount);
    expect(state.isSignedIn, isFalse);
  });

  test('reports a wrong password and does not sign in', () {
    expect(state.login('+63 917 512 4809', 'nope'), AuthResult.wrongPassword);
    expect(state.isSignedIn, isFalse);
  });

  test('a multi-role account can act as every role', () {
    state.login('+63 917 512 4809', 'surgo123');
    expect(state.availableModes,
        [UserMode.passenger, UserMode.earner, UserMode.vehicleOwner]);
    expect(state.mode, UserMode.passenger);

    state.switchToMode(UserMode.vehicleOwner);
    expect(state.mode, UserMode.vehicleOwner);
  });

  test('an account cannot switch to a mode it was not approved for', () {
    state.login('bebot.lim@email.com', 'surgo123');
    expect(state.availableModes, [UserMode.passenger, UserMode.earner]);
    expect(state.mode, UserMode.passenger);

    state.switchToMode(UserMode.vehicleOwner);
    expect(state.mode, UserMode.passenger,
        reason: 'ACC006 is not approved to act as a vehicle owner');

    state.switchToMode(UserMode.earner);
    expect(state.mode, UserMode.earner);
  });

  test('approval gates a mode; eligibility alone does not', () {
    state.login('grace.villaflor@email.com', 'surgo123');
    expect(state.availableModes, [UserMode.passenger, UserMode.vehicleOwner]);
    expect(state.authorizedFor(CapabilityType.vehicleOwner), isTrue);
    expect(state.authorizedFor(CapabilityType.earner), isFalse);
    expect(state.canApplyFor(CapabilityType.earner), isTrue);

    state.switchToMode(UserMode.earner);
    expect(state.mode, UserMode.passenger,
        reason: 'eligible but not approved must not unlock the earner shell');
  });

  test('signing in swaps the wallet and profile the screens read', () {
    expect(state.db.passenger.id, 'P001');

    state.login('grace.villaflor@email.com', 'surgo123');
    expect(state.db.passenger.id, 'P002');
    expect(state.db.passengerWalletBalance, 124000);
    expect(state.db.passengerTransactions, isNotEmpty);

    state.logout();
    expect(state.db.passenger.id, 'P001');
    expect(state.db.passengerWalletBalance, 85000);
  });

  test('registration creates and signs into a fresh passenger account', () {
    final result = state.register(
      name: 'Test User',
      phone: '+63 900 000 0000',
      email: 'test.user@example.com',
      password: 'hunter2',
    );
    expect(result, RegisterResult.ok);
    expect(state.isSignedIn, isTrue);
    expect(state.db.passenger.id, isNot('P001'));
    expect(state.db.passenger.name, 'Test User');
    expect(state.availableModes, [UserMode.passenger]);

    // The new account can sign in again on the same seed.
    state.logout();
    expect(state.login('test.user@example.com', 'hunter2'), AuthResult.ok);
  });

  test('registration refuses an identifier that is already taken', () {
    final result = state.register(
      name: 'Impostor',
      phone: '+63 917 512 4809',
      email: 'impostor@example.com',
      password: 'hunter2',
    );
    expect(result, RegisterResult.identifierTaken);
  });
}
