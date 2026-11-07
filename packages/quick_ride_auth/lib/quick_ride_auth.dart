import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class QuickRideAuth {
  QuickRideAuth._();

  static User? get currentUser =>
      QuickRideBackend.isInitialized
          ? QuickRideBackend.client.auth.currentUser
          : null;

  static Stream<AuthState> get authStateChanges =>
      QuickRideBackend.client.auth.onAuthStateChange;

  static Future<bool> signInWithGoogle({required String redirectTo}) {
    return QuickRideBackend.client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectTo,
    );
  }

  static Future<void> signOut() => QuickRideBackend.client.auth.signOut();
}
