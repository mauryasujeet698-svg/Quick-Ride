import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

export 'package:latlong2/latlong.dart';

/// Lightweight OpenStreetMap-based maps, geocoding, routing and GPS foundation.
class QuickRideMaps {
  QuickRideMaps._();

  static const String defaultLanguage = 'en';
  static const String tileUrl = String.fromEnvironment(
    'OSM_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String photonBaseUrl = String.fromEnvironment(
    'PHOTON_BASE_URL',
    defaultValue: 'https://photon.komoot.io',
  );
  static const String osrmBaseUrl = String.fromEnvironment(
    'OSRM_BASE_URL',
    defaultValue: 'https://router.project-osrm.org',
  );

  static final http.Client _http = http.Client();

  /// Allows widget tests to replace the map canvas. Production leaves this null.
  static Widget Function(BuildContext context, QuickRideMapView view)?
      mapWidgetOverride;

  static bool get isConfigured => tileUrl.startsWith('https://') ||
      tileUrl.startsWith('http://');

  /// Kept as a no-op for app entrypoint compatibility after removing Mapbox.
  static void configure() {}

  static Future<geo.Position> currentPosition() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled. Enable GPS and try again.');
    }
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      throw StateError(
        'Location permission was not granted. You can still choose a pickup manually.',
      );
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
          notificationTitle: 'Quick Ride Captain location',
          notificationText:
              'Location is shared while you are online or completing a ride.',
          enableWakeLock: true,
        ),
      ),
    );
  }

  static Uri _photonUri(String path, Map<String, String> query) {
    final base = Uri.parse(photonBaseUrl);
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
  }

  static Future<List<QuickRideSearchResult>> searchSuggestions({
    required String query,
    LatLng? proximity,
    String language = defaultLanguage,
  }) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final uri = _photonUri('/api/', {
      'q': text,
      'limit': '8',
      'lang': language,
      'bbox': '68.1,6.5,97.4,37.6',
      if (proximity != null) 'lon': proximity.longitude.toString(),
      if (proximity != null) 'lat': proximity.latitude.toString(),
      if (proximity != null) 'zoom': '12',
    });
    final response = await _http
        .get(uri, headers: const {'Accept': 'application/geo+json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('OpenStreetMap place search is unavailable (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? const [];
    return features
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['geometry'] is Map && item['properties'] is Map)
        .map((item) {
          final geometry = Map<String, dynamic>.from(item['geometry'] as Map);
          final coordinates = geometry['coordinates'] as List<dynamic>? ?? const [];
          final properties = Map<String, dynamic>.from(item['properties'] as Map);
          if (coordinates.length < 2 ||
              coordinates[0] is! num ||
              coordinates[1] is! num) {
            return null;
          }
          final longitude = (coordinates[0] as num).toDouble();
          final latitude = (coordinates[1] as num).toDouble();
          final name = properties['name']?.toString() ??
              properties['street']?.toString() ??
              properties['city']?.toString() ??
              'Location';
          final address = [
            properties['housenumber'],
            properties['street'],
            properties['district'],
            properties['city'],
            properties['state'],
            properties['postcode'],
            properties['country'],
          ].whereType<String>().where((value) => value.trim().isNotEmpty).toSet().join(', ');
          final id = '${properties['osm_type'] ?? 'osm'}:${properties['osm_id'] ?? ''}';
          return QuickRideSearchResult(
            mapboxId: id,
            point: LatLng(latitude, longitude),
            name: name,
            address: address.isEmpty ? name : address,
            resultType: (properties['type'] ?? properties['osm_value'] ?? '').toString(),
          );
        })
        .whereType<QuickRideSearchResult>()
        .toList(growable: false);
  }

  static Future<String> reverseGeocode(
    LatLng point, {
    String language = defaultLanguage,
  }) async {
    final uri = _photonUri('/reverse', {
      'lon': point.longitude.toString(),
      'lat': point.latitude.toString(),
      'lang': language,
    });
    final response = await _http
        .get(uri, headers: const {'Accept': 'application/geo+json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('OpenStreetMap address lookup failed (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? const [];
    if (features.isEmpty || features.first is! Map) {
      return 'Selected location (${point.latitude.toStringAsFixed(5)}, '
          '${point.longitude.toStringAsFixed(5)})';
    }
    final properties =
        Map<String, dynamic>.from((features.first as Map)['properties'] as Map? ?? const {});
    final parts = [
      properties['name'],
      properties['housenumber'],
      properties['street'],
      properties['district'],
      properties['city'],
      properties['state'],
      properties['postcode'],
      properties['country'],
    ].whereType<String>().where((value) => value.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Selected location' : parts.toSet().join(', ');
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) async {
    final coordinates =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
    final base = Uri.parse(osrmBaseUrl);
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/route/v1/driving/$coordinates',
      queryParameters: {
        'alternatives': 'false',
        'overview': 'full',
        'geometries': 'geojson',
        'steps': includeSteps ? 'true' : 'false',
      },
    );
    final response = await _http.get(uri).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      throw StateError('OpenStreetMap route service is unavailable (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (payload['code'] != 'Ok') {
      throw StateError((payload['message'] ?? 'No drivable route found.').toString());
    }
    final routes = payload['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty || routes.first is! Map) {
      throw StateError('The routing service returned no drivable route.');
    }
    final route = Map<String, dynamic>.from(routes.first as Map);
    final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
    final rawCoordinates = geometry['coordinates'] as List<dynamic>? ?? const [];
    final points = rawCoordinates
        .whereType<List<dynamic>>()
        .where((pair) => pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map((pair) => LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ))
        .toList(growable: false);
    if (points.length < 2) {
      throw StateError('The routing service returned an incomplete route.');
    }

    final steps = <QuickRideRouteStep>[];
    if (includeSteps) {
      final legs = route['legs'] as List<dynamic>? ?? const [];
      for (final rawLeg in legs) {
        if (rawLeg is! Map) continue;
        final rawSteps = (rawLeg as Map)['steps'] as List<dynamic>? ?? const [];
        for (final raw in rawSteps) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          final maneuver = Map<String, dynamic>.from(item['maneuver'] as Map? ?? const {});
          final location = maneuver['location'] as List<dynamic>? ?? const [];
          final instruction = maneuver['instruction']?.toString() ??
              _osrmInstruction(maneuver);
          steps.add(QuickRideRouteStep(
            instruction: instruction,
            location: location.length >= 2 && location[0] is num && location[1] is num
                ? LatLng((location[1] as num).toDouble(), (location[0] as num).toDouble())
                : null,
            distanceMeters: (item['distance'] as num?)?.toDouble() ?? 0,
            durationSeconds: (item['duration'] as num?)?.toDouble() ?? 0,
          ));
        }
      }
    }

    return QuickRideRoute(
      points: points,
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
      steps: steps,
    );
  }

  static String _osrmInstruction(Map<String, dynamic> maneuver) {
    final type = (maneuver['type'] ?? '').toString().replaceAll('_', ' ');
    final modifier = (maneuver['modifier'] ?? '').toString();
    final road = (maneuver['ref'] ?? maneuver['name'] ?? '').toString();
    final action = switch (type) {
      'depart' => 'Start',
      'arrive' => 'You have arrived',
      'turn' => 'Turn',
      'new name' => 'Continue',
      'continue' => 'Continue',
      'merge' => 'Merge',
      'on ramp' => 'Take the ramp',
      'off ramp' => 'Take the exit ramp',
      'fork' => 'Keep at the fork',
      'roundabout' || 'rotary' => 'Enter the roundabout',
      'end of road' => 'At the end of the road, turn',
      _ => 'Continue',
    };
    final direction = modifier.isEmpty ? '' : ' $modifier';
    final roadText = road.isEmpty ? '' : ' onto $road';
    return '$action$direction$roadText'.trim();
  }
}

/// Small wrapper so feature screens do not depend on a specific map SDK.
class QuickRideMapController {
  QuickRideMapController._(this._controller);

  final fm.MapController _controller;
  bool _ready = false;

  void _markReady() => _ready = true;

  void moveTo(LatLng point, {double? zoom}) {
    if (!_ready) return;
    final currentZoom = _controller.camera.zoom;
    _controller.move(point, zoom ?? currentZoom);
  }

  void fitRoute(List<LatLng> points, {EdgeInsets padding = const EdgeInsets.fromLTRB(36, 175, 36, 250)}) {
    if (!_ready || points.length < 2) return;
    final bounds = LatLngBounds.fromPoints(points);
    _controller.fitCamera(fm.CameraFit.bounds(bounds: bounds, padding: padding));
  }

  void rotate(double degrees) {
    if (!_ready) return;
    _controller.rotate(degrees);
  }
}

class QuickRideSearchResult {
  const QuickRideSearchResult({
    required this.mapboxId,
    required this.point,
    required this.name,
    required this.address,
    required this.resultType,
  });
  /// Stable OSM object identifier (retained name for compatibility with app code).
  final String mapboxId;
  final LatLng point;
  final String name;
  final String address;
  final String resultType;
}

class QuickRidePlace {
  const QuickRidePlace({
    required this.point,
    required this.name,
    required this.address,
  });
  final LatLng point;
  final String name;
  final String address;
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

/// Shared OpenStreetMap map with current position, pickup/dropoff markers and route.
class QuickRideMapView extends StatefulWidget {
  const QuickRideMapView({
    super.key,
    this.initialCenter,
    this.initialZoom = 13,
    this.showUserLocation = true,
    this.currentPosition,
    this.pickup,
    this.destination,
    this.routePoints = const [],
    this.onMapCreated,
    this.onTap,
    this.followCurrentPosition = false,
    this.navigationCamera = false,
    this.recenterSignal = 0,
    this.fitRouteBottomInset = 300,
    this.userAgentPackageName = 'com.quickride.customer',
  });

  final LatLng? initialCenter;
  final double initialZoom;
  final bool showUserLocation;
  final LatLng? currentPosition;
  final LatLng? pickup;
  final LatLng? destination;
  final List<LatLng> routePoints;
  final ValueChanged<QuickRideMapController>? onMapCreated;
  final ValueChanged<LatLng>? onTap;
  final bool followCurrentPosition;
  final bool navigationCamera;
  final int recenterSignal;
  final double fitRouteBottomInset;
  final String userAgentPackageName;

  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  late final fm.MapController _controller;
  late final QuickRideMapController _publicController;
  bool _userMovedCamera = false;
  double _lastZoom = 13;

  @override
  void initState() {
    super.initState();
    _controller = fm.MapController();
    _publicController = QuickRideMapController._(_controller);
  }

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final routeChanged = !listEquals(oldWidget.routePoints, widget.routePoints);
    if (routeChanged && !widget.navigationCamera && widget.routePoints.length >= 2) {
      _publicController.fitRoute(
        widget.routePoints,
        padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset),
      );
    }
    if (widget.recenterSignal != oldWidget.recenterSignal) {
      _userMovedCamera = false;
      final point = widget.currentPosition ?? widget.initialCenter;
      if (point != null) {
        _publicController.moveTo(point, zoom: widget.navigationCamera ? 17 : 15.5);
      }
    } else if (widget.followCurrentPosition &&
        !_userMovedCamera &&
        widget.currentPosition != null &&
        oldWidget.currentPosition != widget.currentPosition) {
      _publicController.moveTo(
        widget.currentPosition!,
        zoom: widget.navigationCamera ? 17 : _lastZoom,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _pin(Color color, IconData icon, {double size = 42}) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.52),
      );

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) return override(context, widget);

    final initial = widget.currentPosition ??
        widget.initialCenter ??
        const LatLng(20.5937, 78.9629);
    final markers = <fm.Marker>[];
    if (widget.currentPosition != null) {
      markers.add(fm.Marker(
        point: widget.currentPosition!,
        width: 38,
        height: 38,
        child: Container(
          decoration: BoxDecoration(
            color: widget.showUserLocation
                ? const Color(0xFF2563EB)
                : const Color(0xFF0F766E),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: const [
              BoxShadow(color: Color(0x44000000), blurRadius: 8),
            ],
          ),
          child: Icon(
            widget.showUserLocation ? Icons.navigation_rounded : Icons.electric_rickshaw,
            color: Colors.white,
            size: 18,
          ),
        ),
      ));
    }
    if (widget.pickup != null) {
      markers.add(fm.Marker(
        point: widget.pickup!,
        width: 46,
        height: 54,
        alignment: Alignment.topCenter,
        child: _pin(const Color(0xFF159B65), Icons.trip_origin_rounded),
      ));
    }
    if (widget.destination != null) {
      markers.add(fm.Marker(
        point: widget.destination!,
        width: 46,
        height: 54,
        alignment: Alignment.topCenter,
        child: _pin(const Color(0xFFD94747), Icons.flag_rounded),
      ));
    }

    return fm.FlutterMap(
      mapController: _controller,
      options: fm.MapOptions(
        initialCenter: initial,
        initialZoom: widget.initialZoom,
        minZoom: 3,
        maxZoom: 19,
        onTap: widget.onTap == null
            ? null
            : (_, point) => widget.onTap?.call(point),
        onPositionChanged: (camera, hasGesture) {
          _lastZoom = camera.zoom;
          if (hasGesture) _userMovedCamera = true;
        },
        onMapReady: () {
          _publicController._markReady();
          widget.onMapCreated?.call(_publicController);
          if (widget.routePoints.length >= 2 && !widget.navigationCamera) {
            _publicController.fitRoute(
              widget.routePoints,
              padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset),
            );
          }
        },
      ),
      children: [
        fm.TileLayer(
          urlTemplate: QuickRideMaps.tileUrl,
          userAgentPackageName: widget.userAgentPackageName,
          maxNativeZoom: 19,
        ),
        if (widget.routePoints.length >= 2)
          fm.PolylineLayer(
            polylines: [
              fm.Polyline(
                points: widget.routePoints,
                strokeWidth: 6,
                color: const Color(0xFF2167D5),
                borderStrokeWidth: 2,
                borderColor: Colors.white,
              ),
            ],
          ),
        if (markers.isNotEmpty) fm.MarkerLayer(markers: markers),
        const fm.RichAttributionWidget(
          attributions: [
            fm.TextSourceAttribution('© OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }
}
