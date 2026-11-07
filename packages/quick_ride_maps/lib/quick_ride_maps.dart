import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

export 'package:flutter_map/flutter_map.dart';
export 'package:latlong2/latlong.dart';

/// OpenStreetMap-backed map, reverse-geocoding and routing services.
///
/// The public OSM/OSRM/Nominatim endpoints are suitable for development and
/// small QA workloads only. Production deployments should point these base
/// URLs at infrastructure with an availability commitment.
class QuickRideMaps {
  QuickRideMaps._();

  static const String userAgentPackageName = 'in.quickride.app';
  static const String _userAgent =
      'QuickRide/0.1 (+https://github.com/mauryasujeet698-svg/Quick-Ride)';
  static const String tileUrlTemplate = String.fromEnvironment(
    'OSM_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String routingBaseUrl = String.fromEnvironment(
    'OSRM_BASE_URL',
    defaultValue: 'https://router.project-osrm.org',
  );
  static const String geocodingBaseUrl = String.fromEnvironment(
    'NOMINATIM_BASE_URL',
    defaultValue: 'https://nominatim.openstreetmap.org',
  );

  static final http.Client _http = http.Client();
  static final Map<String, String> _geocodeCache = <String, String>{};
  static DateTime _lastGeocodeRequest =
      DateTime.fromMillisecondsSinceEpoch(0);

  static TileLayer openStreetMapLayer() => TileLayer(
        urlTemplate: tileUrlTemplate,
        userAgentPackageName: userAgentPackageName,
        maxZoom: 19,
      );

  static Widget attributionControl() => RichAttributionWidget(
        attributions: [
          TextSourceAttribution(
            '© OpenStreetMap contributors',
            prependCopyright: false,
          ),
        ],
      );

  static Future<geo.Position> currentPosition() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled.');
    }
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      throw StateError('Location permission was not granted.');
    }
    return geo.Geolocator.getCurrentPosition(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  }

  static Stream<geo.Position> watchDriverPosition() {
    return geo.Geolocator.getPositionStream(
      locationSettings: geo.AndroidSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const geo.ForegroundNotificationConfig(
          notificationTitle: 'Quick-Ride driver location',
          notificationText:
              'Location is shared while you are online or completing a ride.',
          enableWakeLock: true,
        ),
      ),
    );
  }

  static Future<String> reverseGeocode(LatLng point) async {
    final key =
        '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';
    final cached = _geocodeCache[key];
    if (cached != null) return cached;

    // Public Nominatim allows at most one request per second. The app only
    // reverse-geocodes an explicit user map selection and caches each result.
    final elapsed = DateTime.now().difference(_lastGeocodeRequest);
    if (elapsed < const Duration(seconds: 1)) {
      await Future<void>.delayed(const Duration(seconds: 1) - elapsed);
    }
    _lastGeocodeRequest = DateTime.now();

    final base = geocodingBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final uri = Uri.parse('$base/reverse').replace(queryParameters: {
      'format': 'jsonv2',
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
      'zoom': '18',
      'addressdetails': '1',
    });
    final response = await _http.get(uri, headers: {
      'User-Agent': _userAgent,
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError(
        'OpenStreetMap address lookup failed (${response.statusCode}).',
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final address = (payload['display_name'] ?? '').toString().trim();
    final result = address.isEmpty
        ? 'Selected location (${point.latitude.toStringAsFixed(5)}, '
            '${point.longitude.toStringAsFixed(5)})'
        : address;
    _geocodeCache[key] = result;
    return result;
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) async {
    final base = routingBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final coordinates =
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';
    final uri = Uri.parse('$base/route/v1/driving/$coordinates')
        .replace(queryParameters: {
      'overview': 'full',
      'geometries': 'geojson',
      'steps': includeSteps ? 'true' : 'false',
      'alternatives': 'false',
    });
    final response = await _http.get(uri, headers: {
      'User-Agent': _userAgent,
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError(
        'OpenStreetMap routing failed (${response.statusCode}).',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (payload['code'] != 'Ok') {
      throw StateError('No drivable route was found for these locations.');
    }
    final routes = payload['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty) {
      throw StateError('No drivable route was found for these locations.');
    }
    final route = Map<String, dynamic>.from(routes.first as Map);
    final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
    final rawCoordinates = geometry['coordinates'] as List<dynamic>? ?? [];
    final points = rawCoordinates
        .whereType<List<dynamic>>()
        .where((pair) =>
            pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map((pair) => LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ))
        .toList(growable: false);
    if (points.length < 2) {
      throw StateError('The routing service returned an incomplete route.');
    }

    final steps = <QuickRideRouteStep>[];
    final legs = route['legs'] as List<dynamic>? ?? const [];
    if (legs.isNotEmpty && legs.first is Map) {
      final rawSteps =
          (legs.first as Map)['steps'] as List<dynamic>? ?? const [];
      for (final rawStep in rawSteps) {
        if (rawStep is! Map) continue;
        final step = Map<String, dynamic>.from(rawStep);
        final maneuver = step['maneuver'] is Map
            ? Map<String, dynamic>.from(step['maneuver'] as Map)
            : <String, dynamic>{};
        final location = maneuver['location'] as List<dynamic>? ?? const [];
        final name = (step['name'] ?? '').toString().trim();
        final type = (maneuver['type'] ?? '').toString();
        final modifier = (maneuver['modifier'] ?? '').toString();
        final instruction = _instruction(type, modifier, name);
        if (instruction.isEmpty) continue;
        steps.add(QuickRideRouteStep(
          instruction: instruction,
          location: location.length >= 2 &&
                  location[0] is num &&
                  location[1] is num
              ? LatLng(
                  (location[1] as num).toDouble(),
                  (location[0] as num).toDouble(),
                )
              : null,
          distanceMeters: (step['distance'] as num?)?.toDouble() ?? 0,
          durationSeconds: (step['duration'] as num?)?.toDouble() ?? 0,
        ));
      }
    }

    return QuickRideRoute(
      points: points,
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
      steps: steps,
    );
  }

  static String _instruction(String type, String modifier, String road) {
    final street = road.isEmpty ? '' : ' onto $road';
    switch (type) {
      case 'depart':
        return road.isEmpty ? 'Start driving' : 'Head towards $road';
      case 'arrive':
        return 'You have arrived';
      case 'turn':
        return 'Turn ${modifier.isEmpty ? 'ahead' : modifier}$street';
      case 'continue':
        return road.isEmpty ? 'Continue straight' : 'Continue on $road';
      case 'roundabout':
      case 'rotary':
        return modifier.isEmpty
            ? 'Enter the roundabout$street'
            : 'Take the ${modifier} exit$street';
      case 'merge':
        return 'Merge${modifier.isEmpty ? '' : ' $modifier'}$street';
      case 'fork':
        return 'Keep ${modifier.isEmpty ? 'straight' : modifier}$street';
      case 'on ramp':
        return 'Take the ramp$street';
      case 'off ramp':
        return 'Take the exit$street';
      default:
        return road.isEmpty ? 'Continue towards your destination' : 'Continue on $road';
    }
  }
}

class QuickRideRoute {
  const QuickRideRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.steps = const [],
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<QuickRideRouteStep> steps;
}

class QuickRideRouteStep {
  const QuickRideRouteStep({
    required this.instruction,
    required this.location,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final String instruction;
  final LatLng? location;
  final double distanceMeters;
  final double durationSeconds;
}
