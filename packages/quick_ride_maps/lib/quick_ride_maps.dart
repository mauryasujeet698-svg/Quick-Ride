import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;
import 'package:quick_ride_core/quick_ride_core.dart';

class QuickRideMaps {
  QuickRideMaps._();

  static void configureToken(QuickRideEnvironment environment) {
    if (environment.mapboxPublicToken.isNotEmpty) {
      MapboxOptions.setAccessToken(environment.mapboxPublicToken);
    }
  }

  static Future<Position> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission was not granted.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  }

  static Stream<Position> watchDriverPosition() {
    return Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Quick-Ride driver location',
          notificationText: 'Location is shared while you are online or completing a ride.',
          enableWakeLock: true,
        ),
      ),
    );
  }
}
