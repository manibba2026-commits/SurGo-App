import '../data/db_service.dart';
import 'attachment_repository.dart';
import 'backend.dart';
import 'catalog_repository.dart';
import 'notification_repository.dart';
import 'pasuyo_repository.dart';
import 'profile_repository.dart';
import 'rental_repository.dart';
import 'ride_location_repository.dart';
import 'ride_repository.dart';
import 'vehicle_repository.dart';
import 'verification_repository.dart';
import 'wallet_repository.dart';

/// The nine data domains the app reads, already bound to one backend.
///
/// This is the composition root for the data layer: a build gets either the
/// Supabase set, through [RepositoryRegistry.supabase], or the seeded set,
/// through [RepositoryRegistry.mock]. There is no per-call fallback from one to
/// the other.
class RepositoryRegistry {
  const RepositoryRegistry({
    required this.profiles,
    required this.catalog,
    required this.vehicles,
    required this.rides,
    required this.rentals,
    required this.pasuyo,
    required this.notifications,
    required this.wallet,
    required this.verifications,
    required this.attachments,
    required this.isSupabaseBacked,
    this.rideLocations,
    this.realtime,
  });

  factory RepositoryRegistry.mock([DbService? database]) {
    final db = database ?? DbService.instance;
    return RepositoryRegistry(
      isSupabaseBacked: false,
      profiles: MockProfileRepository(db),
      catalog: MockCatalogRepository(db),
      vehicles: MockVehicleRepository(db),
      rides: MockRideRepository(db),
      rentals: MockRentalRepository(db),
      pasuyo: MockPasuyoRepository(db),
      notifications: MockNotificationRepository(db),
      wallet: MockWalletRepository(db),
      verifications: MockVerificationRepository(db),
      attachments: const MockAttachmentRepository(),
    );
  }

  factory RepositoryRegistry.supabase(SurgoBackend backend) {
    // Only a backend that can write is allowed to submit; a read-only test
    // double keeps the read surface and refuses submissions.
    final writer = backend is SurgoWriteBackend
        ? backend as SurgoWriteBackend
        : null;
    final storage = backend is SurgoStorageBackend
        ? backend as SurgoStorageBackend
        : null;
    return RepositoryRegistry(
      isSupabaseBacked: true,
      profiles: SupabaseProfileRepository(backend),
      catalog: SupabaseCatalogRepository(backend),
      vehicles: SupabaseVehicleRepository(backend),
      rides: SupabaseRideRepository(backend, writer: writer),
      rideLocations: SupabaseRideLocationRepository(backend),
      realtime: backend is SurgoRealtimeBackend
          ? backend as SurgoRealtimeBackend
          : null,
      rentals: SupabaseRentalRepository(backend, writer: writer),
      pasuyo: SupabasePasuyoRepository(backend, writer: writer),
      notifications: SupabaseNotificationRepository(backend),
      wallet: SupabaseWalletRepository(backend),
      verifications: SupabaseVerificationRepository(backend, writer: writer),
      attachments: SupabaseAttachmentRepository(
        backend,
        writer: writer,
        storage: storage,
      ),
    );
  }

  final ProfileRepository profiles;
  final CatalogRepository catalog;
  final VehicleRepository vehicles;
  final RideRepository rides;
  final RentalRepository rentals;
  final PasuyoRepository pasuyo;
  final NotificationRepository notifications;
  final WalletRepository wallet;
  final VerificationRepository verifications;
  final AttachmentRepository attachments;

  /// Optional tracking reads and invalidations. Read-only backends can poll;
  /// direct constructors and the mock set need not supply either capability.
  final RideLocationRepository? rideLocations;
  final SurgoRealtimeBackend? realtime;

  /// False for the seeded set. Screens use this to decide whether a failure is
  /// a real outage or a test fixture, never to substitute the other set.
  final bool isSupabaseBacked;

  /// What a diagnostics note should say about where this build's data comes
  /// from.
  String get description =>
      isSupabaseBacked ? 'Supabase (read-only)' : 'local mock seed';
}
