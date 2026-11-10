import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'repository_failure.dart';

/// The read surface every Supabase-backed repository uses.
///
/// Kept as an interface so repository tests can drive real parsing logic with a
/// recorded row set, without a network or a generated mock client.
abstract interface class SurgoBackend {
  Future<List<Map<String, dynamic>>> rows({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
    Map<String, List<Object>> whereIn = const {},
    List<String> whereNull = const [],
    String? orderBy,
    bool ascending = false,
    int? limit,
  });

  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  });
}

/// The write surface a repository needs when the user creates a record.
///
/// Kept separate from [SurgoBackend] because most repositories are read-only
/// and their test doubles should not have to stub writes. A writer is only
/// handed to repositories that submit something on the user's behalf, and the
/// database still decides what is allowed: the only write path is a
/// server-side function with an `auth.uid()` check.
abstract interface class SurgoWriteBackend {
  /// Calls a Postgres function. The function, not the client, owns validation
  /// and ownership; this method only carries the parameters.
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  });

  /// Uploads [bytes] to a private bucket under [path].
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  });
}

/// Talks to PostgREST through the app's single [SupabaseClient].
///
/// Only the publishable key is ever used here; the service-role key cannot
/// reach this code path because it is not in the client build.
class SupabaseBackend implements SurgoBackend, SurgoWriteBackend {
  SupabaseBackend({SupabaseClient? client, this.requestTimeout = _timeout})
      : _client = client ?? Supabase.instance.client;

  static const Duration _timeout = Duration(seconds: 20);

  final SupabaseClient _client;
  final Duration requestTimeout;

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
  }) {
    return _guard(() async {
      var query = _client.from(table).select(columns);
      for (final filter in eq.entries) {
        query = query.eq(filter.key, filter.value);
      }
      for (final filter in whereIn.entries) {
        if (filter.value.isEmpty) return const <Map<String, dynamic>>[];
        query = query.inFilter(filter.key, filter.value);
      }
      for (final column in whereNull) {
        query = query.isFilter(column, null);
      }

      PostgrestTransformBuilder<PostgrestList> transform = query;
      if (orderBy != null) {
        transform = transform.order(orderBy, ascending: ascending);
      }
      if (limit != null) transform = transform.limit(limit);
      return await transform.timeout(requestTimeout);
    });
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) {
    return _guard(() async {
      // maybeSingle() reads the first row, so an unfiltered lookup would
      // silently pick an arbitrary record. Callers must pin the identity.
      if (eq.isEmpty) {
        throw ArgumentError('row() requires an eq filter to identify the row');
      }

      var query = _client.from(table).select(columns);
      for (final filter in eq.entries) {
        query = query.eq(filter.key, filter.value);
      }
      return await query.maybeSingle().timeout(requestTimeout);
    });
  }

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) {
    return _guard(
      () => _client.rpc(function, params: params).timeout(requestTimeout),
    );
  }

  @override
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) {
    return _guard(() async {
      // Upsert on a fresh, timestamped path: a resubmission replaces the file
      // it names rather than failing because the object already exists.
      await _client.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: contentType, upsert: true),
          ).timeout(requestTimeout);
    });
  }

  Future<T> _guard<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on RepositoryFailure {
      rethrow;
    } catch (error) {
      throw mapBackendError(error);
    }
  }
}

/// Turns a driver/PostgREST failure into the app's typed failure.
///
/// The mapping is deliberately conservative: an unclassified error stays
/// `unavailable` rather than being reported as offline or denied, because the
/// wrong label sends users to the wrong remedy.
RepositoryFailure mapBackendError(Object error) {
  if (error is RepositoryFailure) return error;

  if (error is TimeoutException) return RepositoryFailure.offline(error);
  if (error is SocketException || error is HandshakeException) {
    return RepositoryFailure.offline(error);
  }

  if (error is PostgrestException) {
    final code = error.code;
    final message = error.message.toLowerCase();

    if (code == 'PGRST116') return RepositoryFailure.notFound(error);
    if (code == '42501' || code == 'PGRST301' || code == '401') {
      return RepositoryFailure.permissionDenied(error);
    }
    // Server-side validation (invalid parameter, constraint, uniqueness,
    // malformed date input). The function's own wording names what to fix.
    if (code == '22007' ||
        code == '22008' ||
        code == '22023' ||
        code == '23505' ||
        code == '23514') {
      return RepositoryFailure.invalidData(error.message, error);
    }
    // Undefined relation or column: the query does not match the deployed
    // schema. Surfacing the database message is the fastest way to see it.
    if (code == '42P01' || code == '42703' || code == '42883') {
      return RepositoryFailure(
        RepositoryFailureKind.unavailable,
        'The data service rejected this query: ${error.message}',
        cause: error,
      );
    }
    if (code == null || code.isEmpty) {
      return isNetworkWording(message)
          ? RepositoryFailure.offline(error)
          : RepositoryFailure.unavailable(error);
    }
    if (message.contains('failed to fetch') ||
        message.contains('network') ||
        message.contains('dns')) {
      return RepositoryFailure.offline(error);
    }
    return RepositoryFailure(
      RepositoryFailureKind.unavailable,
      'The data service could not complete this read.',
      cause: error,
    );
  }

  if (error is AuthException) {
    return RepositoryFailure.permissionDenied(error);
  }
  if (error is ArgumentError || error is StateError) {
    return RepositoryFailure.invalidData('$error', error);
  }
  debugPrint('Unclassified backend error: $error');
  return RepositoryFailure.unavailable(error);
}

bool isNetworkWording(String lowerMessage) =>
    lowerMessage.contains('failed to fetch') ||
    lowerMessage.contains('clientexception') ||
    lowerMessage.contains('socketexception') ||
    lowerMessage.contains('network') ||
    lowerMessage.contains('dns');

/// Stands in for a Supabase build whose client never initialized.
///
/// A build asked for the database, so every read says the database is
/// unreachable. Substituting the seed here would present fake data as the real
/// balance of an account.
class UnreachableBackend implements SurgoBackend, SurgoWriteBackend {
  const UnreachableBackend();

  @override
  Future<dynamic> rpc({
    required String function,
    Map<String, dynamic> params = const {},
  }) async {
    throw RepositoryFailure.unavailable();
  }

  @override
  Future<void> uploadObject({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    throw RepositoryFailure.unavailable();
  }

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
    throw RepositoryFailure.unavailable();
  }

  @override
  Future<Map<String, dynamic>?> row({
    required String table,
    String columns = '*',
    Map<String, Object> eq = const {},
  }) async {
    throw RepositoryFailure.unavailable();
  }
}
