import 'dart:developer' as developer;

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
    var stage = 'Google SDK initialization';
    try {
      _googleInitialization ??= _googleSignIn.initialize(
        serverClientId: _googleWebClientId,
      );
      await _googleInitialization!;

      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthException(
          'Native Google sign-in is not supported on this device.',
        );
      }

      stage = 'Google account selection';
      // Exactly one picker request per user tap. Never silently reopen it.
      final googleAccount = await _googleSignIn.authenticate();

      stage = 'Google ID-token retrieval';
      final idToken = googleAccount.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthException(
          'Google returned no ID token. Verify the Web OAuth client ID and Android package/SHA-1 registrations.',
        );
      }

      stage = 'Supabase Google token exchange';
      return await QuickRideBackend.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
    } catch (error, stackTrace) {
      _googleInitialization = null;
      developer.log(
        'Sign-in failed at $stage: $error',
        name: 'quick_ride.auth',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static Future<void> signOut() async {
    // Clear the native Google/Credential Manager session first. Otherwise a
    // later authenticate() can be treated as a broken account re-auth attempt.
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Local Supabase sign-out must still complete if Google cleanup fails.
    }
    try {
      await QuickRideNotifications.unregisterCurrentDevice();
    } catch (_) {
      // A push-token cleanup failure must not leave the user signed in.
    }
    await QuickRideBackend.client.auth.signOut();
  }
}
