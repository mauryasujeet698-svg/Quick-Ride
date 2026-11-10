import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'src/home_screen.dart';
import 'src/navigation_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  QuickRideMaps.configure();
  final environment = QuickRideEnvironment.fromBuildDefines();
  await QuickRideBackend.initialize(environment);
  await QuickRideNotifications.initialize(appRole: 'driver');
  runApp(const ProviderScope(child: QuickRideDriverApp()));

  QuickRideNotifications.openedMessages.listen((message) {
    final rideId = message.data['ride_id'];
    if (rideId is String && rideId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        QuickRideDriverApp.router.go('/ride/$rideId/navigation');
      });
    }
  });
  final initial = await QuickRideNotifications.consumeInitialMessage();
  final rideId = initial?.data['ride_id'];
  if (rideId is String && rideId.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      QuickRideDriverApp.router.go('/ride/$rideId/navigation');
    });
  }

  QuickRideNotifications.foregroundMessages.listen((message) {
    final notification = message.notification;
    if (notification == null) return;
    final rideId = message.data['ride_id'];
    QuickRideDriverApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text('${notification.title ?? 'Quick-Ride'}\n${notification.body ?? 'You have an update.'}'),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () {
            if (rideId is String && rideId.isNotEmpty) {
              QuickRideDriverApp.router.go('/ride/$rideId/navigation');
            }
          },
        ),
      ),
    );
  });
}

class QuickRideDriverApp extends StatelessWidget {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  const QuickRideDriverApp({super.key});
  static final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const DriverHomeScreen()),
    GoRoute(
      path: '/ride/:rideId/navigation',
      builder: (_, state) => DriverRideNavigationScreen(
        rideId: state.pathParameters['rideId']!,
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        scaffoldMessengerKey: messengerKey,
        title: 'Quick Ride Captain',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
