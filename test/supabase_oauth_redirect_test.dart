import 'package:flutter_test/flutter_test.dart';
import 'package:surgo/auth/supabase_auth_repository.dart';

void main() {
  const native = 'io.supabase.surgo://login-callback';

  test('native OAuth returns through the registered custom scheme', () {
    expect(
      resolveOAuthRedirect(
        isWeb: false,
        base: Uri.parse('https://surgo.vercel.app/'),
        nativeRedirect: native,
      ),
      native,
    );
  });

  test('web OAuth returns to the origin the app is served from', () {
    expect(
      resolveOAuthRedirect(
        isWeb: true,
        base: Uri.parse('https://surgo.vercel.app/#/login'),
        nativeRedirect: native,
      ),
      'https://surgo.vercel.app/',
    );
  });

  test('web OAuth keeps a non-default port and a hosted subpath', () {
    expect(
      resolveOAuthRedirect(
        isWeb: true,
        base: Uri.parse('http://localhost:8080/app/?next=1#/login'),
        nativeRedirect: native,
      ),
      'http://localhost:8080/app/',
    );
  });

  test('web OAuth normalizes a bare origin to a root path', () {
    expect(
      resolveOAuthRedirect(
        isWeb: true,
        base: Uri.parse('http://localhost:8080'),
        nativeRedirect: native,
      ),
      'http://localhost:8080/',
    );
  });
}
