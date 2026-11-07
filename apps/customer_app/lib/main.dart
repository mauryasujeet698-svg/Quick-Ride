import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';

import 'src/booking_screen.dart';
import 'src/home_screen.dart';
import 'src/my_rides_screen.dart';
import 'src/profile_screen.dart';
import 'src/support_screen.dart';
import 'src/tracking_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = QuickRideEnvironment.fromBuildDefines();
  await QuickRideBackend.initialize(environment);
  QuickRideMaps.configureToken(environment);
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
      GoRoute(path: '/book', builder: (_, __) => const CustomerBookingScreen()),
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
  Widget build(BuildContext context) => MaterialApp.router(
        scaffoldMessengerKey: messengerKey,
        title: 'Quick-Ride',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
