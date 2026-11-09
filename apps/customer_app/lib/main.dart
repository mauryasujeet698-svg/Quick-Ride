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
import 'src/support_screen.dart';
import 'src/tracking_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  QuickRideMaps.configure();
  await QuickRideCustomerPreferences.load();
  final environment = QuickRideEnvironment.fromBuildDefines();
  await QuickRideBackend.initialize(environment);
  await QuickRideNotifications.initialize(appRole: 'customer');
  runApp(const ProviderScope(child: QuickRideCustomerApp()));

  QuickRideNotifications.openedMessages.listen((message) {
    final rideId = message.data['ride_id'];
    if (rideId is String && rideId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        QuickRideCustomerApp.router.go('/ride/$rideId');
      });
    }
  });
  final initial = await QuickRideNotifications.consumeInitialMessage();
  final rideId = initial?.data['ride_id'];
  if (rideId is String && rideId.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      QuickRideCustomerApp.router.go('/ride/$rideId');
    });
  }

  QuickRideNotifications.foregroundMessages.listen((message) {
    final notification = message.notification;
    if (notification == null) return;
    final rideId = message.data['ride_id'];
    QuickRideCustomerApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text('${notification.title ?? 'Quick-Ride'}\n${notification.body ?? 'You have an update.'}'),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () {
            if (rideId is String && rideId.isNotEmpty) {
              QuickRideCustomerApp.router.go('/ride/$rideId');
            }
          },
        ),
      ),
    );
  });
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
            if (longitude is! num || latitude is! num || address is! String) return null;
            return RidePoint(
              longitude: longitude.toDouble(),
              latitude: latitude.toDouble(),
              address: address,
            );
          }
          return CustomerBookingScreen(
            initialPickup: parsePoint(extra['pickup']),
            initialDestination: parsePoint(extra['destination']),
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
      GoRoute(path: '/support', builder: (_, state) => CustomerSupportScreen(
        initialRideId: state.uri.queryParameters['rideId'],
      )),
      GoRoute(path: '/profile', builder: (_, __) => const CustomerProfileScreen()),
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
