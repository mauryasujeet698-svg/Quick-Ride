import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@pragma('vm:entry-point')
Future<void> quickRideFirebaseBackgroundHandler(RemoteMessage message) async {
  // Background delivery is handled by the operating system for notification
  // messages. Keep this entry point initialized for data-only message support.
  if (Firebase.apps.isEmpty) {
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if (apiKey.isNotEmpty && appId.isNotEmpty && senderId.isNotEmpty && projectId.isNotEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: senderId,
          projectId: projectId,
        ),
      );
    }
  }
}

class QuickRideNotifications {
  QuickRideNotifications._();

  static bool _initialized = false;
  static String? _appRole;
  static FirebaseMessaging? _messaging;
  static StreamSubscription<AuthState>? _authSubscription;
  static StreamSubscription<String>? _tokenSubscription;
  static StreamSubscription<String>? _unregisteredSubscription;
  static String? _currentInstallationId;
  static StreamSubscription<RemoteMessage>? _openedSubscription;
  static StreamSubscription<RemoteMessage>? _foregroundSubscription;
  static RemoteMessage? _initialMessage;
  static final StreamController<RemoteMessage> _openedMessages =
      StreamController<RemoteMessage>.broadcast();
  static final StreamController<RemoteMessage> _foregroundMessages =
      StreamController<RemoteMessage>.broadcast();

  static Stream<RemoteMessage> get openedMessages => _openedMessages.stream;
  static Stream<RemoteMessage> get foregroundMessages => _foregroundMessages.stream;

  static Future<bool> initialize({required String appRole}) async {
    if (!const {'customer', 'driver', 'admin'}.contains(appRole)) {
      throw ArgumentError.value(appRole, 'appRole', 'Unsupported Quick-Ride app role');
    }
    if (_initialized) return true;
    if (!QuickRideBackend.isInitialized) return false;

    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if (apiKey.isEmpty || appId.isEmpty || senderId.isEmpty || projectId.isEmpty) {
      debugPrint('Quick-Ride push notifications are not configured for this build.');
      return false;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: apiKey,
            appId: appId,
            messagingSenderId: senderId,
            projectId: projectId,
          ),
        );
      }

      _appRole = appRole;
      _messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(quickRideFirebaseBackgroundHandler);

      _openedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
        _openedMessages.add,
      );
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen(
        _foregroundMessages.add,
      );
      _initialMessage = await _messaging!.getInitialMessage();

      _authSubscription ??= QuickRideBackend.client.auth.onAuthStateChange.listen(
        (state) {
          final user = state.session?.user;
          if (user != null) {
            unawaited(_registerToken(user.id));
          }
        },
      );
      // Keep FCM registration-token refresh: the server's FCM HTTP v1 sender
      // targets registration tokens, not Firebase Installation IDs.
      // ignore: deprecated_member_use
      _tokenSubscription ??= _messaging!.onRegistered.listen((installationId) {
        _currentInstallationId = installationId;
        final user = QuickRideBackend.client.auth.currentUser;
        if (user != null) {
          unawaited(_saveToken(user.id, installationId));
        }
      });
      _unregisteredSubscription ??=
          _messaging!.onUnregistered.listen((installationId) {
        _currentInstallationId = null;
        if (!QuickRideBackend.isInitialized) return;
        unawaited(
          QuickRideBackend.client
              .from('device_push_tokens')
              .delete()
              .eq('token', installationId),
        );
      });

      _initialized = true;
      final user = QuickRideBackend.client.auth.currentUser;
      if (user != null) await _registerToken(user.id);
      return true;
    } catch (error, stack) {
      debugPrint('Quick-Ride push initialization failed: $error\n$stack');
      return false;
    }
  }

  static Future<RemoteMessage?> consumeInitialMessage() async {
    final value = _initialMessage;
    _initialMessage = null;
    return value;
  }

  static Future<void> _registerToken(String userId) async {
    final messaging = _messaging;
    if (messaging == null || !QuickRideBackend.isInitialized) return;
    try {
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return;
      }
      // ignore: deprecated_member_use
      // Firebase Messaging 17 registers an installation ID (FID), not
      // the legacy FCM registration token. The active onRegistered listener
      // persists the FID for use with the FCM HTTP v1 send endpoint.
      await messaging.register();
    } catch (error) {
      debugPrint('Quick-Ride could not register this device for push: $error');
    }
  }

  static Future<void> _saveToken(String userId, String token) async {
    if (!QuickRideBackend.isInitialized || _appRole == null) return;
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    await QuickRideBackend.client.from('device_push_tokens').upsert({
      'user_id': userId,
      'token': token,
      'app_role': _appRole,
      'platform': platform,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }

  static Future<void> unregisterCurrentDevice() async {
    if (!_initialized || !QuickRideBackend.isInitialized) return;
    final user = QuickRideBackend.client.auth.currentUser;
    if (user == null) return;
    try {
      // ignore: deprecated_member_use
      final installationId = _currentInstallationId;
      if (installationId == null) return;
      await QuickRideBackend.client
          .from('device_push_tokens')
          .delete()
          .eq('user_id', user.id)
          .eq('token', installationId);
      await _messaging?.unregister();
      _currentInstallationId = null;
    } catch (error) {
      debugPrint('Quick-Ride could not unregister this device: $error');
    }
  }

  static Future<void> dispose() async {
    await _authSubscription?.cancel();
    await _tokenSubscription?.cancel();
    await _unregisteredSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    _authSubscription = null;
    _tokenSubscription = null;
    _unregisteredSubscription = null;
    _currentInstallationId = null;
    _openedSubscription = null;
    _foregroundSubscription = null;
    _messaging = null;
    _appRole = null;
    _initialized = false;
  }
}
