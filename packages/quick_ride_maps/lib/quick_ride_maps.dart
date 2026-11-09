import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

export 'package:latlong2/latlong.dart';

/// Shared Mapbox Maps, Geocoding, Directions and location foundation.
class QuickRideMaps {
  QuickRideMaps._();

  static const String accessToken =
      String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static const String defaultLanguage = 'en';

  static final http.Client _http = http.Client();

  /// Allows widget tests to replace the native Mapbox platform view.
  /// Production builds leave this null and render the real Mapbox SDK view.
  static Widget Function(BuildContext context, QuickRideMapView view)?
      mapWidgetOverride;

  static bool get isConfigured =>
      accessToken.isNotEmpty && accessToken.startsWith('pk.');

  static void configure() {
    if (accessToken.isNotEmpty) {
      mbx.MapboxOptions.setAccessToken(accessToken);
    }
  }

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
      throw StateError('Location permission was not granted. You can still choose a pickup manually.');
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

  static Future<List<QuickRideSearchResult>> searchSuggestions({
    required String query,
    LatLng? proximity,
    String language = defaultLanguage,
  }) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    if (!isConfigured) {
      throw StateError('Mapbox is not configured for this build.');
    }

    // Mapbox Search Box API currently serves the US, Canada and Europe.
    // Quick Ride launches in India, so use Geocoding v6 for India-wide
    // address/street/place search. Geocoding v6 does not include POIs.
    final uri = Uri.https(
      'api.mapbox.com',
      '/search/geocode/v6/forward',
      {
        'q': text,
        'autocomplete': 'true',
        'permanent': 'true',
        'country': 'IN',
        'worldview': 'in',
        'types': 'address,street,neighborhood,locality,place,postcode',
        'limit': '8',
        'language': language,
        'access_token': accessToken,
        if (proximity != null)
          'proximity': '${proximity.longitude},${proximity.latitude}',
      },
    );
    final response = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError(
        'Mapbox address search is unavailable (${response.statusCode}). '
        'Check your Mapbox account and permanent-geocoding entitlement.',
      );
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
          final longitude = (properties['coordinates'] is Map)
              ? (properties['coordinates']['longitude'] as num?)?.toDouble()
              : (coordinates.length >= 2 && coordinates[0] is num
                  ? (coordinates[0] as num).toDouble()
                  : null);
          final latitude = (properties['coordinates'] is Map)
              ? (properties['coordinates']['latitude'] as num?)?.toDouble()
              : (coordinates.length >= 2 && coordinates[1] is num
                  ? (coordinates[1] as num).toDouble()
                  : null);
          return (longitude == null || latitude == null)
              ? null
              : QuickRideSearchResult(
                  mapboxId: (properties['mapbox_id'] ?? item['id'] ?? '').toString(),
                  point: LatLng(latitude, longitude),
                  name: (properties['name'] ?? properties['place_formatted'] ?? 'Location').toString(),
                  address: (properties['full_address'] ??
                          [
                            properties['name'],
                            properties['place_formatted'],
                          ].whereType<String>().where((value) => value.isNotEmpty).join(', '))
                      .toString(),
                  resultType: (properties['feature_type'] ?? '').toString(),
                );
        })
        .whereType<QuickRideSearchResult>()
        .toList(growable: false);
  }

  static Future<String> reverseGeocode(
    LatLng point, {
    String language = defaultLanguage,
  }) async {
    if (!isConfigured) {
      throw StateError('Mapbox is not configured for this build.');
    }
    // Pickup and destination labels are persisted with ride records, so request
    // permanent results. Mapbox requires a payment method or enterprise
    // entitlement for permanent geocoding.
    final uri = Uri.https(
      'api.mapbox.com',
      '/search/geocode/v6/reverse',
      {
        'longitude': point.longitude.toString(),
        'latitude': point.latitude.toString(),
        'language': language,
        'country': 'IN',
        'worldview': 'in',
        'types': 'address,street,neighborhood,locality,place,postcode',
        'permanent': 'true',
        'access_token': accessToken,
      },
    );
    final response = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError(
        'Mapbox address lookup failed (${response.statusCode}). '
        'Check your Mapbox account and permanent-geocoding entitlement.',
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? const [];
    if (features.isEmpty || features.first is! Map) {
      return 'Selected location (${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})';
    }
    final properties =
        Map<String, dynamic>.from((features.first as Map)['properties'] as Map? ?? const {});
    final name = properties['name']?.toString();
    final formatted = properties['place_formatted']?.toString();
    final full = properties['full_address']?.toString();
    if (full != null && full.isNotEmpty) return full;
    final parts = [name, formatted]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? 'Selected location' : parts.join(', ');
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) async {
    if (!isConfigured) {
      throw StateError('Mapbox is not configured for this build.');
    }
    final coordinates =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
    final uri = Uri.https(
      'api.mapbox.com',
      '/directions/v5/mapbox/driving/$coordinates',
      {
        'access_token': accessToken,
        'alternatives': 'false',
        'overview': 'full',
        'geometries': 'geojson',
        'steps': includeSteps ? 'true' : 'false',
        'language': 'en',
      },
    );
    final response = await _http.get(uri).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      throw StateError('Mapbox routing is unavailable (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (payload['code'] != 'Ok') {
      throw StateError((payload['message'] ?? 'No drivable route found.').toString());
    }
    final routes = payload['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty || routes.first is! Map) {
      throw StateError('Mapbox returned no drivable route.');
    }
    final route = Map<String, dynamic>.from(routes.first as Map);
    final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
    final coordinatesJson = geometry['coordinates'] as List<dynamic>? ?? const [];
    final points = coordinatesJson
        .whereType<List<dynamic>>()
        .where((pair) => pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map((pair) => LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ))
        .toList(growable: false);
    if (points.length < 2) throw StateError('Mapbox returned an incomplete route.');

    final steps = <QuickRideRouteStep>[];
    if (includeSteps) {
      final legs = route['legs'] as List<dynamic>? ?? const [];
      if (legs.isNotEmpty && legs.first is Map) {
        final rawSteps = (legs.first as Map)['steps'] as List<dynamic>? ?? const [];
        for (final raw in rawSteps) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          final maneuver =
              Map<String, dynamic>.from(item['maneuver'] as Map? ?? const {});
          final location = maneuver['location'] as List<dynamic>? ?? const [];
          steps.add(QuickRideRouteStep(
            instruction: (maneuver['instruction'] ?? 'Continue along the route').toString(),
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
}

class QuickRideSearchResult {
  const QuickRideSearchResult({
    required this.mapboxId,
    required this.point,
    required this.name,
    required this.address,
    required this.resultType,
  });
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

/// Reusable Mapbox map with the live location puck, route and selected points.
/// The built-in Mapbox logo and attribution ornaments are deliberately retained.
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
  });

  final LatLng? initialCenter;
  final double initialZoom;
  final bool showUserLocation;
  final LatLng? currentPosition;
  final LatLng? pickup;
  final LatLng? destination;
  final List<LatLng> routePoints;
  final ValueChanged<mbx.MapboxMap>? onMapCreated;
  final ValueChanged<LatLng>? onTap;
  final bool followCurrentPosition;
  final bool navigationCamera;
  final int recenterSignal;
  final double fitRouteBottomInset;

  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  mbx.MapboxMap? _map;
  mbx.PointAnnotationManager? _points;
  mbx.PolylineAnnotationManager? _lines;
  bool _annotationsReady = false;
  bool _userMovedCamera = false;
  StreamSubscription<mbx.MapContentGestureContext>? _panSubscription;
  StreamSubscription<mbx.MapContentGestureContext>? _zoomSubscription;

  mbx.Point _mapPoint(LatLng point) =>
      mbx.Point(coordinates: mbx.Position(point.longitude, point.latitude));

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final routeChanged = !listEquals(oldWidget.routePoints, widget.routePoints);
    if (_annotationsReady &&
        (oldWidget.pickup != widget.pickup ||
            oldWidget.destination != widget.destination ||
            routeChanged)) {
      unawaited(_refreshAnnotations());
      if (routeChanged && !widget.navigationCamera && widget.routePoints.length >= 2) {
        unawaited(_fitRoute());
      }
    }
    if (widget.recenterSignal != oldWidget.recenterSignal) {
      _userMovedCamera = false;
      final point = widget.currentPosition ?? widget.initialCenter;
      if (point != null) unawaited(_moveCamera(point, animated: true));
    } else if (widget.followCurrentPosition &&
        !_userMovedCamera &&
        widget.currentPosition != null &&
        oldWidget.currentPosition != widget.currentPosition) {
      unawaited(_moveCamera(widget.currentPosition!, animated: true));
    }
  }

  Future<void> _onMapCreated(mbx.MapboxMap map) async {
    _map = map;
    widget.onMapCreated?.call(map);
    _panSubscription = map.gestures.pan.gestureEvents.listen((_) {
      _userMovedCamera = true;
    });
    _zoomSubscription = map.gestures.zoom.gestureEvents.listen((_) {
      _userMovedCamera = true;
    });
    try {
      if (widget.showUserLocation) {
        await map.location.updateSettings(
          mbx.LocationComponentSettings(
            enabled: true,
            pulsingEnabled: true,
            puckBearingEnabled: true,
            puckBearing: mbx.PuckBearing.HEADING,
            showAccuracyRing: true,
          ),
        );
      }
      _points = await map.annotations.createPointAnnotationManager();
      _lines = await map.annotations.createPolylineAnnotationManager();
      _annotationsReady = true;
      if (widget.onTap != null) {
        map.addInteraction(
          mbx.TapInteraction.onMap((context) {
            final coordinate = context.point.coordinates;
            widget.onTap?.call(
              LatLng(coordinate.lat.toDouble(), coordinate.lng.toDouble()),
            );
          }),
        );
      }
      await _refreshAnnotations();
      final center = widget.currentPosition ?? widget.initialCenter;
      if (center != null) {
        await _moveCamera(center, animated: false);
      }
    } catch (error, stack) {
      debugPrint('Quick Ride Mapbox setup failed: $error\n$stack');
    }
  }

  Future<void> _refreshAnnotations() async {
    final pointManager = _points;
    final lineManager = _lines;
    if (pointManager == null || lineManager == null) return;
    await pointManager.deleteAll();
    await lineManager.deleteAll();

    final linePoints = widget.routePoints;
    if (linePoints.length >= 2) {
      await lineManager.create(
        mbx.PolylineAnnotationOptions(
          geometry: mbx.LineString(
            coordinates: linePoints
                .map((point) => mbx.Position(point.longitude, point.latitude))
                .toList(growable: false),
          ),
          lineColor: 0xFF2167D5,
          lineWidth: 6,
          lineBorderColor: 0xFFFFFFFF,
          lineBorderWidth: 2,
          lineJoin: mbx.LineJoin.ROUND,
        ),
      );
    }

    Future<void> addPoint(LatLng? point, String label, int color) async {
      if (point == null) return;
      await pointManager.create(
        mbx.PointAnnotationOptions(
          geometry: _mapPoint(point),
          textField: label,
          textSize: 13,
          textColor: 0xFFFFFFFF,
          textHaloColor: color,
          textHaloWidth: 9,
          textHaloBlur: 1,
          textOffset: const [0, -1.2],
        ),
      );
    }

    await addPoint(widget.pickup, 'PICKUP', 0xFF159B65);
    await addPoint(widget.destination, 'DROP', 0xFFD94747);
  }

  Future<void> _fitRoute() async {
    final map = _map;
    final points = widget.routePoints;
    if (map == null || points.length < 2) return;
    try {
      final fitted = await map.cameraForCoordinates(
        points.map(_mapPoint).toList(growable: false),
        mbx.MbxEdgeInsets(
          top: 175,
          left: 36,
          bottom: widget.fitRouteBottomInset,
          right: 36,
        ),
        null,
        null,
      );
      await map.flyTo(fitted, mbx.MapAnimationOptions(duration: 800));
    } catch (error) {
      debugPrint('Quick Ride route camera fit failed: $error');
    }
  }

  Future<void> _moveCamera(LatLng point, {required bool animated}) async {
    final map = _map;
    if (map == null) return;
    final options = mbx.CameraOptions(
      center: _mapPoint(point),
      zoom: widget.navigationCamera ? 17 : 15.5,
      pitch: widget.navigationCamera ? 48 : 0,
    );
    if (animated) {
      await map.flyTo(options, mbx.MapAnimationOptions(duration: 700));
    } else {
      map.setCamera(options);
    }
  }

  Future<void> recenter() async {
    final point = widget.currentPosition ?? widget.initialCenter;
    if (point == null) return;
    _userMovedCamera = false;
    await _moveCamera(point, animated: true);
  }

  @override
  void dispose() {
    _panSubscription?.cancel();
    _zoomSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) return override(context, widget);

    final initial = widget.currentPosition ??
        widget.initialCenter ??
        const LatLng(20.5937, 78.9629);
    return Stack(
      fit: StackFit.expand,
      children: [
        mbx.MapWidget(
          key: const ValueKey('quick-ride-mapbox-map'),
          styleUri: mbx.MapboxStyles.STANDARD,
          viewport: mbx.CameraViewportState(
            center: _mapPoint(initial),
            zoom: widget.initialZoom,
          ),
          onMapCreated: _onMapCreated,
        ),
      ],
    );
  }
}
