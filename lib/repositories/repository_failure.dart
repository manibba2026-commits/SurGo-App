/// Why a repository call could not complete.
enum RepositoryFailureKind {
  offline,
  permissionDenied,
  notFound,
  conflict,
  invalidData,
  unavailable,
  unsupported,
  unknown,
}

/// Typed failure raised by every repository.
///
/// Repositories never return fake data on failure. Callers decide whether to
/// show an error, retry, or (in mock mode only) keep using local data.
class RepositoryFailure implements Exception {
  const RepositoryFailure(this.kind, this.message, {this.cause});

  final RepositoryFailureKind kind;
  final String message;
  final Object? cause;

  factory RepositoryFailure.offline([Object? cause]) => RepositoryFailure(
        RepositoryFailureKind.offline,
        'You appear to be offline. Check your connection and try again.',
        cause: cause,
      );

  factory RepositoryFailure.permissionDenied([Object? cause]) =>
      RepositoryFailure(
        RepositoryFailureKind.permissionDenied,
        'You do not have permission to read this data.',
        cause: cause,
      );

  factory RepositoryFailure.notFound([Object? cause]) => RepositoryFailure(
        RepositoryFailureKind.notFound,
        'That record could not be found.',
        cause: cause,
      );

  factory RepositoryFailure.conflict(String message, [Object? cause]) =>
      RepositoryFailure(
        RepositoryFailureKind.conflict,
        message,
        cause: cause,
      );

  factory RepositoryFailure.invalidData(String message, [Object? cause]) =>
      RepositoryFailure(
        RepositoryFailureKind.invalidData,
        message,
        cause: cause,
      );

  factory RepositoryFailure.unavailable([Object? cause]) => RepositoryFailure(
        RepositoryFailureKind.unavailable,
        'The data service is unavailable right now.',
        cause: cause,
      );

  factory RepositoryFailure.unsupported(String message) => RepositoryFailure(
        RepositoryFailureKind.unsupported,
        message,
      );

  bool get isRetryable =>
      kind == RepositoryFailureKind.offline ||
      kind == RepositoryFailureKind.unavailable;

  bool get isPermissionProblem =>
      kind == RepositoryFailureKind.permissionDenied ||
      kind == RepositoryFailureKind.unsupported;

  @override
  String toString() => 'RepositoryFailure(${kind.name}): $message';
}
