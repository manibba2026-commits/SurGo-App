import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// Exercises the verification workflow at the state level: seeding, document
/// gating, submission, and the simulated review that grants the capability.
/// The screen owns its own 1s timer for the same transitions, so those are not
/// re-tested here.
void main() {
  late AppState state;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    state = AppState.instance;
    await state.init();
  });

  setUp(() => state.logout());

  test('seeded applications load from applications.json', () {
    final accountIds = {
      for (final app in state.verificationApplications) app.accountId,
    };
    expect(accountIds, containsAll({'ACC002', 'ACC006', 'ACC010'}));
  });

  test('an approved seed shows an approved status with no application', () {
    state.login('grace.villaflor@email.com', 'surgo123'); // ACC002 owner
    expect(state.verificationStatusFor(CapabilityType.vehicleOwner),
        VerificationStatus.approved);
  });

  test('a draft requires every document before it can submit', () {
    state.login('+63 930 215 8888', 'surgo123'); // ACC010 rider
    final app = state.verificationFor(CapabilityType.rider);
    expect(app, isNotNull);
    expect(app!.status, VerificationStatus.draft);
    expect(app.isComplete, isFalse);
    expect(
        state.submitVerification(app.id), VerificationSubmitResult.incomplete);
  });

  test('submit is refused for an application that is not the account’s own',
      () {
    state.login('+63 931 326 9977', 'surgo123'); // ACC011
    expect(state.submitVerification('VAPP-ACC002-OWNER'),
        VerificationSubmitResult.notFound);
  });

  test('the passenger capability never needs verification', () {
    state.login('+63 917 512 4809', 'surgo123'); // ACC001
    expect(state.startVerification(CapabilityType.passenger), isNull,
        reason: 'passenger is the base capability, already approved');
  });

  test('a rider application auto-approves and grants the capability', () {
    state.login('+63 930 215 8888', 'surgo123'); // ACC010
    final seeded = state.db.accounts.firstWhere((a) => a.id == 'ACC010');
    expect(seeded.authorizedFor(CapabilityType.rider), isFalse);

    final app = state.startVerification(CapabilityType.rider)!;
    expect(
        state.submitVerification(app.id), VerificationSubmitResult.incomplete);

    expect(state.markDocumentUploaded(app.id, 'dl'), isFalse,
        reason: 'a seeded draft already has the license uploaded');
    expect(state.markDocumentUploaded(app.id, 'orcr'), isTrue);
    expect(app.isComplete, isTrue);

    expect(state.submitVerification(app.id), VerificationSubmitResult.ok);
    expect(app.status, VerificationStatus.submitted);

    // Exactly at the under-review boundary it has not advanced yet.
    state.processDueVerifications(
        at: app.submittedAt!.add(const Duration(seconds: 2)));
    expect(app.status, VerificationStatus.underReview);

    state.processDueVerifications(
        at: app.submittedAt!.add(const Duration(seconds: 5)));
    expect(app.status, VerificationStatus.approved);
    expect(state.verificationStatusFor(CapabilityType.rider),
        VerificationStatus.approved);

    final refreshed = state.db.accounts.firstWhere((a) => a.id == 'ACC010');
    expect(refreshed.authorizedFor(CapabilityType.rider), isTrue);
    expect(
        refreshed.eligibleCapabilities, isNot(contains(CapabilityType.rider)));
    expect(state.currentAccount?.authorizedFor(CapabilityType.rider), isTrue,
        reason: 'the current session follows the granted capability');
  });

  test('resubmission resets a needs-resubmission application to draft', () {
    state.login('+63 926 771 3390', 'surgo123'); // ACC006
    expect(state.verificationStatusFor(CapabilityType.vehicleOwner),
        VerificationStatus.needsResubmission);

    final app = state.startVerification(CapabilityType.vehicleOwner)!;
    expect(app.status, VerificationStatus.draft);
    expect(app.reviewerNote, isNull);
  });
}
