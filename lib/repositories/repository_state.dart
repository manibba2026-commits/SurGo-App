import 'repository_failure.dart';

enum RepositoryStatus { idle, loading, data, empty, failure }

/// Explicit state for a repository-backed read.
///
/// Keeping loading/empty/failure separate from data prevents screens from
/// rendering a spinner, an empty state and stale rows at the same time.
class RepositoryState<T> {
  const RepositoryState._(this.status, this.data, this.failure);

  const RepositoryState.idle() : this._(RepositoryStatus.idle, null, null);

  const RepositoryState.loading()
      : this._(RepositoryStatus.loading, null, null);

  RepositoryState.data(T value) : this._(RepositoryStatus.data, value, null);

  const RepositoryState.empty() : this._(RepositoryStatus.empty, null, null);

  const RepositoryState.failure(RepositoryFailure failure)
      : this._(RepositoryStatus.failure, null, failure);

  final RepositoryStatus status;
  final T? data;
  final RepositoryFailure? failure;

  bool get isIdle => status == RepositoryStatus.idle;
  bool get isLoading => status == RepositoryStatus.loading;
  bool get isEmpty => status == RepositoryStatus.empty;
  bool get hasData => status == RepositoryStatus.data;
  bool get hasFailure => status == RepositoryStatus.failure;
}
