import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'src/admin_home_screen.dart';
import 'src/operations_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = QuickRideEnvironment.fromBuildDefines();
  await QuickRideBackend.initialize(environment);
  QuickRideMaps.configureToken(environment);
  await QuickRideNotifications.initialize(appRole: 'admin');
  runApp(const ProviderScope(child: QuickRideAdminApp()));

  QuickRideNotifications.openedMessages.listen((_) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      QuickRideAdminApp.router.go('/operations');
    });
  });
  final initial = await QuickRideNotifications.consumeInitialMessage();
  if (initial != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      QuickRideAdminApp.router.go('/operations');
    });
  }

  QuickRideNotifications.foregroundMessages.listen((message) {
    final notification = message.notification;
    if (notification == null) return;
    QuickRideAdminApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text('${notification.title ?? 'Quick-Ride'}\n${notification.body ?? 'You have an operations update.'}'),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () => QuickRideAdminApp.router.go('/operations'),
        ),
      ),
    );
  });
}

class QuickRideAdminApp extends StatelessWidget {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  const QuickRideAdminApp({super.key});
  static final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const AdminHomeScreen()),
    GoRoute(path: '/operations', builder: (_, __) => const AdminOperationsScreen()),
  ]);

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        scaffoldMessengerKey: messengerKey,
        title: 'Quick-Ride Admin',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
