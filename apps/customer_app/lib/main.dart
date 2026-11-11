import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

import 'customer_preferences.dart';
import 'src/booking_screen.dart';
import 'src/home_screen.dart';
import 'src/my_rides_screen.dart';
import 'src/profile_screen.dart';
import 'src/services_screen.dart';
import 'src/support_screen.dart';
import 'src/tracking_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: QuickRideCustomerBootstrap()));
}

class QuickRideCustomerBootstrap extends StatefulWidget {
  const QuickRideCustomerBootstrap({super.key});

  @override
  State<QuickRideCustomerBootstrap> createState() =>
      _QuickRideCustomerBootstrapState();
}

class _QuickRideCustomerBootstrapState extends State<QuickRideCustomerBootstrap> {
  bool _ready = false;
  StreamSubscription<dynamic>? _openedSubscription;
  StreamSubscription<dynamic>? _foregroundSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      QuickRideMaps.configure();
      await QuickRideCustomerPreferences.load();

      final environment = QuickRideEnvironment.fromBuildDefines();
      await QuickRideBackend.initialize(environment);
      if (QuickRideBackend.isInitialized) {
        // Push setup is optional: a missing Firebase config must not prevent
        // customers from opening the app or using guest map/search features.
        await QuickRideNotifications.initialize(appRole: 'customer');
        _openedSubscription =
            QuickRideNotifications.openedMessages.listen(_handleOpenedMessage);
        _foregroundSubscription =
            QuickRideNotifications.foregroundMessages.listen(_handleForegroundMessage);
        final initial = await QuickRideNotifications.consumeInitialMessage();
        if (initial != null) _handleOpenedMessage(initial);
      }
    } catch (error, stack) {
      debugPrint('Quick-Ride Customer startup failed: $error\n$stack');
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  void _handleOpenedMessage(dynamic message) {
    final data = message.data;
    final rideId = data['ride_id'];
    if (rideId is String && rideId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        QuickRideCustomerApp.router.go('/ride/${Uri.encodeComponent(rideId)}');
      });
    }
  }

  void _handleForegroundMessage(dynamic message) {
    final notification = message.notification;
    if (notification == null) return;
    final rideId = message.data['ride_id'];
    QuickRideCustomerApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          '${notification.title ?? 'Quick-Ride'}\n'
          '${notification.body ?? 'You have an update.'}',
        ),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () {
            if (rideId is String && rideId.isNotEmpty) {
              QuickRideCustomerApp.router.go(
                '/ride/${Uri.encodeComponent(rideId)}',
              );
            }
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _openedSubscription?.cancel();
    _foregroundSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return MaterialApp(
        title: 'Quick Ride',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 14),
                Text('Starting Quick Ride…'),
              ],
            ),
          ),
        ),
      );
    }
    return const QuickRideCustomerApp();
  }
}

class QuickRideCustomerApp extends StatelessWidget {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  const QuickRideCustomerApp({super.key});

  static final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const CustomerHomeScreen()),
      GoRoute(
        path: '/book',
        builder: (_, state) {
          final extra = state.extra;
          if (extra is! Map) return const CustomerBookingScreen();
          RidePoint? parsePoint(dynamic value) {
            if (value is! Map) return null;
            final data = Map<String, dynamic>.from(value);
            final longitude = data['longitude'];
            final latitude = data['latitude'];
            final address = data['address'];
            if (longitude is! num || latitude is! num || address is! String) {
              return null;
            }
            return RidePoint(
              longitude: longitude.toDouble(),
              latitude: latitude.toDouble(),
              address: address,
              pincode: data['pincode']?.toString(),
            );
          }
          return CustomerBookingScreen(
            initialPickup: parsePoint(extra['pickup']),
            initialDestination: parsePoint(extra['destination']),
            initialVehicleCategoryId:
                (extra['vehicleCategoryId'] as num?)?.toInt(),
            initialVehicleCategoryCode:
                extra['vehicleCategoryCode']?.toString(),
          );
        },
      ),
      GoRoute(
        path: '/ride/:rideId',
        builder: (_, state) => CustomerRideTrackingScreen(
          rideId: state.pathParameters['rideId']!,
        ),
      ),
      GoRoute(path: '/my-rides', builder: (_, __) => const CustomerRidesScreen()),
      GoRoute(path: '/services', builder: (_, __) => const CustomerServicesScreen()),
      GoRoute(
        path: '/support',
        builder: (_, state) => CustomerSupportScreen(
          initialRideId: state.uri.queryParameters['rideId'],
        ),
      ),
      GoRoute(path: '/profile', builder: (_, __) => const CustomerProfileScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const CustomerSettingsScreen()),
      GoRoute(
        path: '/privacy-policy',
        builder: (_, __) => const CustomerInformationScreen(page: 'privacy'),
      ),
      GoRoute(path: '/terms', builder: (_, __) => const CustomerInformationScreen(page: 'terms')),
      GoRoute(path: '/about', builder: (_, __) => const CustomerInformationScreen(page: 'about')),
    ],
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: QuickRideCustomerPreferences.themeMode,
        builder: (context, themeMode, _) =>
            ValueListenableBuilder<Locale>(
          valueListenable: QuickRideCustomerPreferences.locale,
          builder: (context, locale, __) => MaterialApp.router(
            scaffoldMessengerKey: messengerKey,
            title: 'Quick Ride',
            theme: QuickRideTheme.light(),
            darkTheme: QuickRideTheme.dark(),
            themeMode: themeMode,
            locale: locale,
            supportedLocales: const [Locale('en'), Locale('hi')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            routerConfig: router,
          ),
        ),
      );
}
