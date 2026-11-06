import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/services/supabase_bootstrap.dart';

void main() {
  test('Supabase config points at the hosted project with a publishable key',
      () {
    final uri = Uri.parse(SupabaseConfig.url);
    expect(uri.scheme, 'https');
    expect(uri.host, 'lrhgktxmavnhjatqzbzr.supabase.co');
    expect(SupabaseConfig.publishableKey, startsWith('sb_publishable_'));
    expect(SupabaseConfig.publishableKey, isNot(contains('sb_secret_')));
  });
}
