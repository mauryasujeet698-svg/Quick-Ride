import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'src/home_screen.dart';
import 'src/navigation_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = QuickRideEnvironment.fromBuildDefines();
  await QuickRideBackend.initialize(environment);
  QuickRideMaps.configureToken(environment);
  runApp(const ProviderScope(child: QuickRideDriverApp()));
}

class QuickRideDriverApp extends StatelessWidget {
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
        title: 'Quick-Ride Driver',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
