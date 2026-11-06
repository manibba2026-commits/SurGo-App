import '../auth/auth_models.dart';
import '../data/db_models.dart';
import '../data/db_service.dart';
import 'backend.dart';
import 'backend_rows.dart';
import 'repository_failure.dart';

/// Reads the identity rows that back a signed-in user's capabilities.
abstract interface class ProfileRepository {
  Future<ProfileRecord?> fetchProfile(String profileId);

  /// Every role row for [profileId], approved or not.
  Future<List<RoleGrantRecord>> fetchRoleGrants(String profileId);

  /// Role tokens whose status is `approved`.
  Future<List<String>> fetchApprovedRoles(String profileId);

  Future<ProviderProfileRecord?> fetchProviderProfile(String profileId);

  Future<List<VerificationApplicationRecord>> fetchVerificationApplications(
      String profileId);

  /// Whether the account may act as a passenger, earner or vehicle owner.
  Future<Set<CapabilityType>> fetchApprovedCapabilities(String profileId);
}

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(SurgoBackend backend) : _backend = backend;

  static const String _profileColumns =
      'id, full_name, first_name, email, phone, avatar_path, account_status, '
      'rating, total_rides, last_seen_at, created_at';

  final SurgoBackend _backend;

  @override
  Future<ProfileRecord?> fetchProfile(String profileId) async {
    final row = await _backend.row(
      table: 'profiles',
      columns: _profileColumns,
      eq: {'id': profileId},
    );
    return row == null ? null : ProfileRecord.fromRow(row);
  }

  @override
  Future<List<RoleGrantRecord>> fetchRoleGrants(String profileId) async {
    final rows = await _backend.rows(
      table: 'user_roles',
      columns: 'role, status, approved_at',
      eq: {'profile_id': profileId},
    );
    return [for (final row in rows) RoleGrantRecord.fromRow(row)];
  }

  @override
  Future<List<String>> fetchApprovedRoles(String profileId) async {
    final grants = await fetchRoleGrants(profileId);
    return [
      for (final grant in grants)
        if (grant.isApproved) grant.role
    ];
  }

  @override
  Future<ProviderProfileRecord?> fetchProviderProfile(String profileId) async {
    final row = await _backend.row(
      table: 'provider_profiles',
      columns: 'profile_id, provider_type, service_area_id, display_name, bio, '
          'capabilities, is_available, rating, total_trips',
      eq: {'profile_id': profileId},
    );
    return row == null ? null : ProviderProfileRecord.fromRow(row);
  }

  @override
  Future<List<VerificationApplicationRecord>> fetchVerificationApplications(
      String profileId) async {
    final rows = await _backend.rows(
      table: 'verification_applications',
      columns: 'id, profile_id, capability_type, status, submitted_at, '
          'reviewed_at, decided_at, rejection_reason, '
          'documents:verification_documents(id, application_id, document_type, '
          'label, document_number, storage_path, expires_at, is_required, '
          'status, rejection_reason)',
      eq: {'profile_id': profileId},
      orderBy: 'created_at',
    );
    return [for (final row in rows) VerificationApplicationRecord.fromRow(row)];
  }

  @override
  Future<Set<CapabilityType>> fetchApprovedCapabilities(
      String profileId) async {
    return capabilitiesFromRoles(await fetchApprovedRoles(profileId));
  }
}

/// Serves the same contract from the in-memory seed.
///
/// The seed keys people by `P001` / `R001` ids, so a Supabase auth uuid is
/// resolved through [DbService.findAccountForIdentity] first. An auth user with
/// no seeded account genuinely has no local profile, and this returns null
/// rather than inventing one.
class MockProfileRepository implements ProfileRepository {
  MockProfileRepository([DbService? database])
      : _db = database ?? DbService.instance;

  final DbService _db;

  Account? _accountFor(String profileId) {
    // Seed ids can be an account id or one of its linked profile ids, while a
    // real session carries a Supabase auth uuid. Accept all three shapes.
    for (final account in _db.accounts) {
      if (account.id == profileId ||
          account.passengerId == profileId ||
          account.riderId == profileId ||
          account.ownerId == profileId) {
        return account;
      }
    }
    return _db.findAccountForIdentity(authUserId: profileId);
  }

  @override
  Future<ProfileRecord?> fetchProfile(String profileId) async {
    final profile = _profileById(profileId) ?? _profileForAccount(profileId);
    if (profile == null) return null;
    return ProfileRecord(
      id: profileId,
      fullName: profile.name,
      firstName: profile.firstName,
      email: profile.email.isEmpty ? null : profile.email,
      phone: profile.phone.isEmpty ? null : profile.phone,
      accountStatus: 'active',
      rating: profile.rating,
      totalRides: profile.totalRides,
      createdAt: DateTime(profile.memberSince),
    );
  }

  @override
  Future<List<RoleGrantRecord>> fetchRoleGrants(String profileId) async {
    final account = _accountFor(profileId);
    if (account == null) return const [];
    final caps = account.approvedCapabilities;
    return [
      for (final capability in caps)
        RoleGrantRecord(
          role: _roleToken(capability),
          status: 'approved',
        ),
    ];
  }

  @override
  Future<List<String>> fetchApprovedRoles(String profileId) async {
    final grants = await fetchRoleGrants(profileId);
    return [for (final grant in grants) grant.role];
  }

  @override
  Future<ProviderProfileRecord?> fetchProviderProfile(String profileId) async {
    final earner = _db.earners[profileId] ?? _earnerForAccount(profileId);
    if (earner == null) return null;
    return ProviderProfileRecord(
      profileId: profileId,
      providerType: 'earner',
      capabilityTokens: [
        for (final capability in earner.activeCapabilities) capability.jsonKey,
      ],
      displayName: earner.name,
      isAvailable: true,
      rating: earner.rating,
      totalTrips: earner.totalTrips,
    );
  }

  @override
  Future<List<VerificationApplicationRecord>> fetchVerificationApplications(
      String profileId) async {
    final account = _accountFor(profileId);
    if (account == null) return const [];
    return [
      for (final application in _db.verificationApplications)
        if (application.accountId == account.id)
          VerificationApplicationRecord(
            id: application.id,
            profileId: profileId,
            capabilityType: _roleToken(application.capabilityType),
            status: _dbStatus(application.status),
            submittedAt: application.submittedAt,
            reviewedAt: application.reviewedAt,
            decidedAt: application.status == VerificationStatus.approved ||
                    application.status == VerificationStatus.rejected
                ? application.reviewedAt
                : null,
            rejectionReason: application.status == VerificationStatus.rejected
                ? application.reviewerNote
                : null,
            documents: [
              for (final document in application.documents)
                VerificationDocumentRecord(
                  id: document.id,
                  applicationId: application.id,
                  documentType: document.id,
                  label: document.label,
                  status: document.uploaded ? 'approved' : 'pending',
                  isRequired: document.required,
                ),
            ],
          ),
    ];
  }

  @override
  Future<Set<CapabilityType>> fetchApprovedCapabilities(
      String profileId) async {
    final account = _accountFor(profileId);
    return account?.usableCapabilities ?? const {};
  }

  /// The seeded profile that already carries this id, when the caller passed a
  /// seed id such as `P001` instead of an auth uuid.
  _NameAndContact? _profileById(String id) {
    final passenger = _db.passengers[id];
    if (passenger != null) return _fromPassenger(passenger);
    final owner = _db.owners[id];
    if (owner != null) return _fromOwner(owner);
    final earner = _db.earners[id];
    if (earner == null) return null;
    return _NameAndContact(
      name: earner.name,
      firstName: _first(earner.name),
      phone: earner.phone,
      email: earner.email,
      rating: earner.rating,
      totalRides: earner.totalTrips,
      memberSince: earner.memberSince,
    );
  }

  _NameAndContact? _profileForAccount(String profileId) {
    final account = _accountFor(profileId);
    if (account == null) return null;
    if (account.passengerId != null) {
      final passenger = _db.passengers[account.passengerId];
      if (passenger != null) return _fromPassenger(passenger);
    }
    if (account.riderId != null) {
      final earner = _db.earners[account.riderId];
      if (earner != null) {
        return _NameAndContact(
          name: earner.name,
          firstName: _first(earner.name),
          phone: earner.phone,
          email: earner.email,
          rating: earner.rating,
          totalRides: earner.totalTrips,
          memberSince: earner.memberSince,
        );
      }
    }
    if (account.ownerId != null) {
      final owner = _db.owners[account.ownerId];
      if (owner != null) return _fromOwner(owner);
    }
    return null;
  }

  EarnerProfile? _earnerForAccount(String profileId) {
    final account = _accountFor(profileId);
    if (account?.riderId == null) return null;
    return _db.earners[account!.riderId];
  }

  _NameAndContact _fromPassenger(PassengerProfile p) => _NameAndContact(
        name: p.name,
        firstName: p.firstName,
        phone: p.phone,
        email: p.email,
        rating: p.rating,
        totalRides: p.totalRides,
        memberSince: p.memberSince,
      );

  _NameAndContact _fromOwner(VehicleOwnerProfile o) => _NameAndContact(
        name: o.name,
        firstName: _first(o.name),
        phone: o.phone,
        email: o.email,
        rating: o.rating,
        totalRides: o.totalRentals,
        memberSince: o.memberSince,
      );

  static String _first(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.isEmpty || parts.first.isEmpty ? name : parts.first;
  }

  static String _roleToken(CapabilityType capability) => switch (capability) {
        CapabilityType.passenger => 'passenger',
        CapabilityType.earner => 'earner',
        CapabilityType.rider => 'rider',
        CapabilityType.vehicleOwner => 'vehicle_owner',
      };

  static String _dbStatus(VerificationStatus status) => switch (status) {
        VerificationStatus.draft => 'draft',
        VerificationStatus.submitted => 'submitted',
        VerificationStatus.underReview => 'under_review',
        VerificationStatus.approved => 'approved',
        VerificationStatus.rejected => 'rejected',
        VerificationStatus.needsResubmission => 'needs_resubmission',
      };
}

class _NameAndContact {
  const _NameAndContact({
    required this.name,
    required this.firstName,
    required this.phone,
    required this.email,
    required this.rating,
    required this.totalRides,
    required this.memberSince,
  });

  final String name;
  final String firstName;
  final String phone;
  final String email;
  final double rating;
  final int totalRides;
  final int memberSince;
}

/// Kept so [MockProfileRepository] can raise the same typed failure the
/// Supabase side does if the seed has not been loaded yet.
RepositoryFailure seedNotLoaded() => RepositoryFailure.unavailable();
