/// Selects where business data comes from.
///
/// Defaults to [DataSourceMode.supabase] — the hosted database is the source
/// of truth, so an ordinary build reads it. Tests, the offline presentation
/// demo and local development opt back into the seed with
/// `--dart-define=SURGO_DATA_SOURCE=mock`.
enum DataSourceMode { mock, supabase }

class DataSourceConfig {
  const DataSourceConfig._();

  static const String _raw = String.fromEnvironment(
    'SURGO_DATA_SOURCE',
    defaultValue: 'supabase',
  );

  static const DataSourceMode mode = _raw == 'mock'
      ? DataSourceMode.mock
      : DataSourceMode.supabase;

  static bool get usesSupabase => mode == DataSourceMode.supabase;

  static bool get usesMock => mode == DataSourceMode.mock;

  static String get description => usesSupabase ? 'Supabase' : 'local mock';
}
