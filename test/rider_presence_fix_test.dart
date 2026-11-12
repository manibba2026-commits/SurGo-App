import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/auth_models.dart';
import 'package:surgo/repositories/backend_rows.dart';
import 'package:surgo/repositories/repository_registry.dart';
import 'package:surgo/repositories/ride_repository.dart';
import 'package:surgo/data/db_models.dart';
import 'package:surgo/state/app_state.dart';

/// A hosted rider must share a device fix when going online; a demo identity
/// keeps its seeded simulated fix.
class _Rides extends MockRideRepository {
  _Rides() : super();

  bool? online;
  double? latitude;
  double? longitude;
  int calls = 0;

  @override
  Future<RiderPresenceRecord> setPresence({
    required bool online,
    double? latitude,
    double? longitude,
    double? headingDegrees,
    String? barangayId,
  }) async {
    calls++;
    this.online = online;
    this.latitude = latitude;
    this.longitude = longitude;
    return const RiderPresenceRecord(
      profileId: 'rider-1',
      isOnline: true,
      isAvailable: true,
    );
  }
}

RepositoryRegistry _registry(_Rides rides) {
  final mock = RepositoryRegistry.mock();
  return RepositoryRegistry(
    profiles: mock.profiles,
    catalog: mock.catalog,
    vehicles: mock.vehicles,
    rides: rides,
    rentals: mock.rentals,
    pasuyo: mock.pasuyo,
    notifications: mock.notifications,
    wallet: mock.wallet,
    verifications: mock.verifications,
    attachments: mock.attachments,
    isSupabaseBacked: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = AppState.instance;

  setUp(() {
    state.identity = null;
    state.riderFixReader = null;
  });

  tearDown(() {
    state.identity = null;
    state.riderFixReader = null;
  });

  test('a real rider going online sends the device fix', () async {
    final rides = _Rides();
    state.configureRepositories(_registry(rides));
    var reads = 0;
    state.riderFixReader = () async {
      reads++;
      return const MapPoint(9.0789, 126.2011);
    };

    await state.setHostedRiderOnline(true);

    expect(reads, 1);
    expect(rides.online, isTrue);
    expect(rides.latitude, 9.0789);
    expect(rides.longitude, 126.2011);
  });

  test('a demo rider keeps the seeded fix', () async {
    state.identity = const SurgoIdentity(
      userId: 'demo-rider',
      capabilities: {CapabilityType.rider},
      eligibleCapabilities: {},
      roles: {'rider'},
      providers: {'phone'},
      isDemoAccount: true,
    );
    final rides = _Rides();
    state.configureRepositories(_registry(rides));
    var reads = 0;
    state.riderFixReader = () async {
      reads++;
      return const MapPoint(9.0789, 126.2011);
    };

    await state.setHostedRiderOnline(true);

    expect(reads, 0);
    expect(rides.online, isTrue);
    expect(rides.latitude, isNull);
    expect(rides.longitude, isNull);
  });

  test('going offline does not read the device location', () async {
    final rides = _Rides();
    state.configureRepositories(_registry(rides));
    var reads = 0;
    state.riderFixReader = () async {
      reads++;
      return const MapPoint(9.0789, 126.2011);
    };

    await state.setHostedRiderOnline(false);

    expect(reads, 0);
    expect(rides.online, isFalse);
    expect(rides.latitude, isNull);
    expect(rides.longitude, isNull);
  });

  test('a denied or unavailable fix sends no coordinates', () async {
    final rides = _Rides();
    state.configureRepositories(_registry(rides));
    state.riderFixReader = () async => null;

    await state.setHostedRiderOnline(true);

    expect(rides.online, isTrue);
    expect(rides.latitude, isNull);
    expect(rides.longitude, isNull);
  });
}
