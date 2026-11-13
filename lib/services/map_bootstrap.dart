import 'dart:async';

import 'package:http/http.dart' as http;

import '../state/app_state.dart';
import 'geoapify_service.dart';

/// Map stack readiness: the MapTiler style document and the Geoapify function.
///
/// Startup fetches the style once and keeps the JSON so every [SurgoMap] can
/// pass it straight to MapLibre instead of waiting on the network again. The
/// Geoapify warm-up runs after a hosted session is restored, because the
/// function authenticates the caller; it only proves the token and connection
/// are warm, and a failure here never blocks the UI.
class MapBootstrap {
  MapBootstrap._();

  static final MapBootstrap instance = MapBootstrap._();

  static const styleId = '01a1cb9c-c444-77a5-893d-2d51c9539591';
  static const _key = String.fromEnvironment('MAPTILER_API_KEY');

  static bool get hasKey => _key.isNotEmpty;

  static String get styleUrl =>
      'https://api.maptiler.com/maps/$styleId/style.json'
      '?key=${Uri.encodeQueryComponent(_key)}';

  String? _styleJson;
  bool _started = false;
  bool _geoapifyWarmed = false;
  bool _listening = false;

  /// A raw style document when the warm-up finished, otherwise the style URL.
  /// MapLibre accepts either form on every platform.
  String get styleSource => _styleJson ?? styleUrl;

  /// True once [styleSource] is the prefetched document rather than a URL.
  bool get stylePrefetched => _styleJson != null;

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_prefetchStyle());
    if (!_listening) {
      _listening = true;
      AppState.instance.addListener(_maybeWarmGeoapify);
    }
    _maybeWarmGeoapify();
  }

  Future<void> _prefetchStyle() async {
    if (!hasKey) return;
    try {
      final response = await http
          .get(Uri.parse(styleUrl))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return;
      final body = response.body.trim();
      if (!body.startsWith('{') || body.length < 64) return;
      _styleJson = body;
    } catch (_) {
      // The map still loads from the URL; warming is only an optimization.
    }
  }

  void _maybeWarmGeoapify() {
    if (_geoapifyWarmed) return;
    final state = AppState.instance;
    if (!state.isSignedIn || !state.repositories.isSupabaseBacked) return;
    _geoapifyWarmed = true;
    unawaited(_warmGeoapify());
  }

  Future<void> _warmGeoapify() async {
    try {
      await GeoapifyService()
          .autocomplete('Tandag')
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // A cold or rate-limited call is not an error the user needs to see;
      // the picker issues its own request when it opens.
    }
  }
}
