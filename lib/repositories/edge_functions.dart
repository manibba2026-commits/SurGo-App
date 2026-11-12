import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';
import 'repository_failure.dart';

/// Calls an Edge Function as the signed-in user.
///
/// Kept apart from [SurgoBackend] on purpose: the read gateway can only ever
/// select, and everything this phase writes — a device token, a live position,
/// a push — is done by a function that runs with the service role after
/// checking the caller's own JWT. A client cannot widen that check by
/// constructing a request, because it never holds the key it runs with.
abstract interface class EdgeInvoker {
  Future<void> invoke(String name, Map<String, Object?> body);
}

/// Invokes through the app's single [SupabaseClient].
///
/// The publishable key and the user's access token are what reach the function;
/// a service-account credential is never part of a client build.
class SupabaseEdgeInvoker implements EdgeInvoker {
  SupabaseEdgeInvoker({SupabaseClient? client, this.requestTimeout = _timeout})
      : _client = client ?? Supabase.instance.client;

  static const Duration _timeout = Duration(seconds: 12);

  final SupabaseClient _client;
  final Duration requestTimeout;

  @override
  Future<void> invoke(String name, Map<String, Object?> body) async {
    try {
      // Only a function that accepted the call comes back as a response; a
      // refused one is thrown as FunctionException carrying its status, which
      // is where the useful distinction between "offline" and "not yours"
      // lives.
      await _client.functions.invoke(name, body: body).timeout(requestTimeout);
    } on RepositoryFailure {
      rethrow;
    } catch (error) {
      throw mapEdgeError(error);
    }
  }
}

/// Turns a function failure into the app's typed failure.
///
/// A 401 or 403 is a rule the caller did not meet — not a broken connection —
/// so it must not be reported as one, and must never be retried in a loop.
RepositoryFailure mapEdgeError(Object error) {
  if (error is RepositoryFailure) return error;
  if (error is FunctionException) {
    if (error.status == 0) {
      // No status means the request never reached the function at all.
      return RepositoryFailure.offline(error);
    }
    if (error.status == 401 || error.status == 403) {
      // The function checked the caller and said no. Wording matters here: a
      // read refusal would send the user to their permissions, when the real
      // answer is that this trip or token is not theirs to change.
      return RepositoryFailure(
        RepositoryFailureKind.permissionDenied,
        'This action is not allowed for your account.',
        cause: error,
      );
    }
    if (error.status == 400 || error.status == 422) {
      return RepositoryFailure.invalidData('${error.details}', error);
    }
    if (error.status == 500 &&
        error.details is Map &&
        error.details['error'] == 'not_configured') {
      // The function ran but its provider key is absent. Saying "offline" sends
      // the user to their connection when the build itself is incomplete.
      return RepositoryFailure.unsupported(
        'This service is not configured for this build.',
      );
    }
    return RepositoryFailure.unavailable(error);
  }
  if (error is TimeoutException) return RepositoryFailure.offline(error);
  if (error is SocketException || error is HandshakeException) {
    return RepositoryFailure.offline(error);
  }
  if (error is AuthException) return RepositoryFailure.permissionDenied(error);
  return mapBackendError(error);
}

/// Stands in for a Supabase build whose client never initialized.
///
/// Refusing loudly is the point: a token or a position that could not be sent
/// is reported as unavailable rather than quietly dropped, and no seed value
/// takes its place.
class UnreachableEdgeInvoker implements EdgeInvoker {
  const UnreachableEdgeInvoker();

  @override
  Future<void> invoke(String name, Map<String, Object?> body) async {
    throw RepositoryFailure.unavailable();
  }
}
