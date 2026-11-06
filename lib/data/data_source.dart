/// Selects where business data comes from.
///
/// Defaults to [DataSourceMode.mock] so tests, demos and offline development
/// keep the existing in-memory behaviour. A production build opts in with
/// `--dart-define=SURGO_DATA_SOURCE=supabase`.
enum DataSourceMode { mock, supabase }

class DataSourceConfig {
  const DataSourceConfig._();

  static const String _raw = String.fromEnvironment(
    'SURGO_DATA_SOURCE',
    defaultValue: 'mock',
  );

  static const DataSourceMode mode =
      _raw == 'supabase' ? DataSourceMode.supabase : DataSourceMode.mock;

  static bool get usesSupabase => mode == DataSourceMode.supabase;

  static bool get usesMock => mode == DataSourceMode.mock;

  static String get description =>
      usesSupabase ? 'Supabase (read-only)' : 'local mock';
}
