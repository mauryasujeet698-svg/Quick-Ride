import 'package:google_sign_in/google_sign_in.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class QuickRideAuth {
  QuickRideAuth._();

  static const String _googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static Future<void>? _googleInitialization;

  static User? get currentUser =>
      QuickRideBackend.isInitialized
          ? QuickRideBackend.client.auth.currentUser
          : null;

  static Stream<AuthState> get authStateChanges =>
      QuickRideBackend.client.auth.onAuthStateChange;

  /// Native Google account selection followed by a Supabase ID-token exchange.
  ///
  /// [redirectTo] remains in the signature for existing app callers. It is
  /// intentionally unused: native authentication returns directly to Quick Ride.
  static Future<AuthResponse> signInWithGoogle({
    required String redirectTo,
  }) async {
    if (!QuickRideBackend.isInitialized) {
      throw const AuthException('Quick Ride could not connect to its sign-in service.');
    }
    if (_googleWebClientId.isEmpty) {
      throw const AuthException(
        'Google sign-in is not configured. Add the GOOGLE_WEB_CLIENT_ID build secret.',
      );
    }
    _googleInitialization ??= _googleSignIn.initialize(
      serverClientId: _googleWebClientId,
    );
    await _googleInitialization!;

    if (!_googleSignIn.supportsAuthenticate()) {
      throw const AuthException(
        'Native Google sign-in is not supported on this device.',
      );
    }

    final googleAccount = await _googleSignIn.authenticate();
    final idToken = googleAccount.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const AuthException(
        'Google did not return an ID token. Check the Android OAuth client configuration.',
      );
    }

    final authorization = await googleAccount.authorizationClient
            .authorizationForScopes(const ['email']) ??
        await googleAccount.authorizationClient
            .authorizeScopes(const ['email']);
    final accessToken = authorization.accessToken;
    if (accessToken.isEmpty) {
      throw const AuthException(
        'Google did not grant the access token required to finish sign-in.',
      );
    }

    return QuickRideBackend.client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  static Future<void> signOut() async {
    await QuickRideNotifications.unregisterCurrentDevice();
    await QuickRideBackend.client.auth.signOut();
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Supabase session is already closed; native account cleanup is best-effort.
    }
  }
}
