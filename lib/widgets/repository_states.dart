import 'package:flutter/material.dart';

import '../repositories/repository_failure.dart';
import '../repositories/repository_state.dart';
import '../state/app_state.dart';
import '../state/domain_cache.dart';
import '../theme/app_colors.dart';
import 'common.dart';

/// Presents one repository read: loading, empty, failure or data.
///
/// The screen's own rebuild listener stays where it is — this widget only asks
/// [DomainCache] for the slot once, when it first opens, and then renders the
/// state the cache reports.
class RepositoryView<T> extends StatefulWidget {
  const RepositoryView({
    super.key,
    required this.slot,
    required this.data,
    this.cache,
    this.loading,
    this.empty,
    this.failure,
  });

  final DomainSlot slot;

  /// Built with the loaded value. This is the screen's existing content.
  final Widget Function(BuildContext context, T value) data;

  /// Test hook: a screen can be pointed at a cache that is not the app's.
  final DomainCache? cache;

  final Widget? loading;

  /// Shown when the read succeeded and returned nothing.
  final Widget Function(BuildContext context)? empty;

  /// Shown when the read failed. Receives the typed failure.
  final Widget Function(BuildContext context, RepositoryFailure failure)?
      failure;

  @override
  State<RepositoryView<T>> createState() => _RepositoryViewState<T>();
}

class _RepositoryViewState<T> extends State<RepositoryView<T>> {
  DomainCache? _attached;

  DomainCache get _cache =>
      _attached ??= widget.cache ?? AppState.instance.cache;

  @override
  void initState() {
    super.initState();
    _cache.addListener(_onCacheChanged);
    _cache.ensure(widget.slot);
  }

  @override
  void dispose() {
    _attached?.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = _cache.stateOf<T>(widget.slot);
    final failure = state.failure;
    return switch (state.status) {
      RepositoryStatus.loading ||
      RepositoryStatus.idle =>
        widget.loading ?? const SbListLoading(),
      RepositoryStatus.empty =>
        widget.empty?.call(context) ?? const SbEmptyState(),
      RepositoryStatus.failure =>
        widget.failure?.call(context, failure!) ??
            SbFailureState(
              failure: failure!,
              onRetry: () => _cache.retry(widget.slot),
            ),
      RepositoryStatus.data => widget.data(context, state.data as T),
    };
  }
}

/// A repository value shown where a spinner would move the layout.
///
/// Badges, counters and inline amounts have no room for a loading or failure
/// block, so every non-data state collapses to [placeholder]. The read itself
/// still comes from the cache, so a failed read shows nothing rather than a
/// seeded number.
class RepositoryInline<T> extends StatelessWidget {
  final DomainSlot slot;
  final Widget Function(BuildContext context, T value) data;
  final Widget placeholder;
  final DomainCache? cache;

  const RepositoryInline({
    super.key,
    required this.slot,
    required this.data,
    this.cache,
    this.placeholder = const SizedBox.shrink(),
  });

  @override
  Widget build(BuildContext context) => RepositoryView<T>(
        slot: slot,
        cache: cache,
        loading: placeholder,
        empty: (_) => placeholder,
        failure: (_, __) => placeholder,
        data: data,
      );
}

/// The waiting presentation for a repository-backed list or record.
class SbListLoading extends StatelessWidget {
  final String? label;

  const SbListLoading({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AppColors.primaryLight,
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 10),
              Text(label!,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The read succeeded and there is nothing to show.
class SbEmptyState extends StatelessWidget {
  final String message;
  final IconData icon;

  const SbEmptyState({
    super.key,
    this.message = 'Nothing here yet.',
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: AppColors.muted2),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// The read failed, said in the terms the failure already carries.
///
/// Offline, permission-denied and unsupported reads are different answers, and
/// telling them apart is what keeps a locked table from looking like a broken
/// connection. Retry re-runs the same slot rather than serving seed rows.
class SbFailureState extends StatelessWidget {
  final RepositoryFailure failure;
  final VoidCallback? onRetry;

  const SbFailureState({super.key, required this.failure, this.onRetry});

  String get _heading => switch (failure.kind) {
        RepositoryFailureKind.offline => 'You appear to be offline',
        RepositoryFailureKind.permissionDenied => 'This is not visible to you',
        RepositoryFailureKind.unsupported => 'Not available in this build',
        RepositoryFailureKind.unavailable => 'The data service is unavailable',
        RepositoryFailureKind.notFound => 'Nothing was found to show',
        RepositoryFailureKind.conflict => 'This changed underneath you',
        RepositoryFailureKind.invalidData => 'This data could not be read',
        RepositoryFailureKind.unknown => 'This could not be loaded',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 22, color: _tint),
          const SizedBox(height: 8),
          Text(_heading,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(failure.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            SbOutlineButton(
              label: 'Try again',
              icon: Icons.refresh,
              block: false,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }

  IconData get _icon => switch (failure.kind) {
        RepositoryFailureKind.offline => Icons.wifi_off_rounded,
        RepositoryFailureKind.permissionDenied => Icons.lock_outline,
        RepositoryFailureKind.unsupported => Icons.block_outlined,
        _ => Icons.error_outline,
      };

  Color get _tint => switch (failure.kind) {
        RepositoryFailureKind.offline => AppColors.yellow,
        RepositoryFailureKind.permissionDenied => AppColors.danger,
        _ => AppColors.muted2,
      };
}
