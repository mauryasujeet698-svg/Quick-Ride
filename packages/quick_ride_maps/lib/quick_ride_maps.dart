import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart' as fm;

export 'package:latlong2/latlong.dart';

/// Mapbox-backed location search, address lookup, routing and native map view.
class QuickRideMaps {
  QuickRideMaps._();

  static const String defaultLanguage = 'en';
  static const String accessToken = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static final http.Client _http = http.Client();
  static final Random _random = Random.secure();
  static String? _activeSearchSessionToken;
  static DateTime? _searchSessionStartedAt;
  // Mapbox raster style tiles keep the native Flutter renderer lightweight
  // while using Mapbox's actual Streets basemap instead of public OSM tiles.
  static const String _mapboxStyleId =
      String.fromEnvironment('MAPBOX_STYLE_ID', defaultValue: 'mapbox/streets-v12');

  static String get tileUrl {
    _requireToken();
    return 'https://api.mapbox.com/styles/v1/' +
        _mapboxStyleId +
        '/tiles/256/{z}/{x}/{y}?access_token=' +
        Uri.encodeComponent(_normalizedAccessToken);
  }

  /// Allows widget tests to replace the native map canvas. Production leaves this null.
  static Widget Function(BuildContext context, QuickRideMapView view)?
      mapWidgetOverride;

  static String get _normalizedAccessToken => accessToken.trim();

  static bool get isConfigured => _normalizedAccessToken.startsWith('pk.');

  static void _requireToken() {
    if (!isConfigured) {
      throw StateError(
        'Mapbox is not configured. Add a public Mapbox token (pk.*) to the MAPBOX_ACCESS_TOKEN build secret.',
      );
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
      throw StateError(
        'Location permission was not granted. You can still search for a pickup location.',
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

  static String _sessionToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static Uri _searchUri(String path, Map<String, String> parameters) {
    _requireToken();
    return Uri.https('api.mapbox.com', '/search/searchbox/v1$path', {
      ...parameters,
      'access_token': accessToken,
    });
  }

  static Future<List<QuickRideSearchResult>> searchSuggestions({
    required String query,
    LatLng? proximity,
    String language = defaultLanguage,
  }) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final startedAt = _searchSessionStartedAt;
    if (_activeSearchSessionToken == null ||
        startedAt == null ||
        DateTime.now().difference(startedAt) > const Duration(minutes: 2)) {
      _activeSearchSessionToken = _sessionToken();
      _searchSessionStartedAt = DateTime.now();
    }
    final sessionToken = _activeSearchSessionToken!;
    final uri = _searchUri('/suggest', {
      'q': text,
      'session_token': sessionToken,
      'limit': '8',
      'language': language,
      'country': 'IN',
      if (proximity != null)
        'proximity': '${proximity.longitude},${proximity.latitude}',
    });
    final response = await _http
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('Mapbox place search failed (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final suggestions = payload['suggestions'] as List<dynamic>? ?? const [];
    return suggestions
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .where((item) => item['mapbox_id'] is String)
        .map((item) {
          final name = (item['name'] ?? item['place_formatted'] ?? 'Location').toString();
          final address = (item['full_address'] ?? item['place_formatted'] ?? name).toString();
          return QuickRideSearchResult(
            mapboxId: item['mapbox_id'].toString(),
            sessionToken: sessionToken,
            point: const LatLng(0, 0),
            name: name,
            address: address,
            resultType: (item['feature_type'] ?? '').toString(),
            postalCode: _postalCode(address),
          );
        })
        .toList(growable: false);
  }

  static Future<QuickRidePlace> retrieveSuggestion(
    QuickRideSearchResult suggestion,
  ) async {
    _requireToken();
    if (suggestion.sessionToken == null || suggestion.sessionToken!.isEmpty) {
      throw StateError('This search result has expired. Search again and select a result.');
    }
    final uri = _searchUri('/retrieve/${Uri.encodeComponent(suggestion.mapboxId)}', {
      'session_token': suggestion.sessionToken!,
    });
    final response = await _http
        .get(uri, headers: const {'Accept': 'application/geo+json'})
        .timeout(const Duration(seconds: 12));
    if (_activeSearchSessionToken == suggestion.sessionToken) {
      _activeSearchSessionToken = null;
      _searchSessionStartedAt = null;
    }
    if (response.statusCode != 200) {
      throw StateError('Mapbox could not retrieve the selected place (${response.statusCode}).');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? const [];
    if (features.isEmpty || features.first is! Map) {
      throw StateError('Mapbox returned no coordinates for this place.');
    }
    final feature = Map<String, dynamic>.from(features.first as Map);
    final geometry = Map<String, dynamic>.from(feature['geometry'] as Map? ?? const {});
    final coordinates = geometry['coordinates'] as List<dynamic>? ?? const [];
    if (coordinates.length < 2 || coordinates[0] is! num || coordinates[1] is! num) {
      throw StateError('Mapbox returned invalid coordinates for this place.');
    }
    final properties = Map<String, dynamic>.from(feature['properties'] as Map? ?? const {});
    final context = Map<String, dynamic>.from(properties['context'] as Map? ?? const {});
    final postcodeContext = context['postcode'];
    final contextPostalCode = postcodeContext is Map
        ? (postcodeContext['name'] ?? postcodeContext['text'])?.toString()
        : null;
    final longitude = (coordinates[0] as num).toDouble();
    final latitude = (coordinates[1] as num).toDouble();
    final name = (properties['name'] ?? suggestion.name).toString();
    final address = (properties['full_address'] ??
            properties['place_formatted'] ??
            suggestion.address)
        .toString();
    return QuickRidePlace(
      point: LatLng(latitude, longitude),
      name: name,
      address: address,
      postalCode: _postalCode(address) ?? contextPostalCode,
    );
  }

  static String? _postalCode(String value) {
    final match = RegExp(r'(?<![0-9])[1-9][0-9]{5}(?![0-9])').firstMatch(value);
    return match?.group(0);
  }

  static Future<String> reverseGeocode(
    LatLng point, {
    String language = defaultLanguage,
  }) async {
    _requireToken();
    final uri = Uri.https('api.mapbox.com', '/search/geocode/v6/reverse', {
      'longitude': point.longitude.toString(),
      'latitude': point.latitude.toString(),
      'language': language,
      'country': 'IN',
      'access_token': accessToken,
    });
    final response = await _http
        .get(uri, headers: const {'Accept': 'application/geo+json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('Mapbox address lookup failed (' + response.statusCode.toString() + ').');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? const [];
    if (features.isEmpty || features.first is! Map) {
      return 'Selected location (' +
          point.latitude.toStringAsFixed(5) + ', ' +
          point.longitude.toStringAsFixed(5) + ')';
    }
    final properties =
        Map<String, dynamic>.from((features.first as Map)['properties'] as Map? ?? const {});
    final context = Map<String, dynamic>.from(
      properties['context'] as Map? ?? const {},
    );
    final postcodeContext = context['postcode'];
    final postcode = postcodeContext is Map
        ? (postcodeContext['name'] ?? postcodeContext['text'])?.toString()
        : null;
    final address = (properties['full_address'] ??
            properties['place_formatted'] ??
            properties['name'] ??
            'Selected location')
        .toString();
    if (postcode != null &&
        RegExp(r'^[1-9][0-9][0-9][0-9][0-9][0-9]$').hasMatch(postcode) &&
        !address.contains(postcode)) {
      return address + ', ' + postcode;
    }
    return address;
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) async {
    _requireToken();
    final coordinates =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
    final uri = Uri.https(
      'api.mapbox.com',
      '/directions/v5/mapbox/driving/$coordinates',
      {
        'alternatives': 'false',
        'overview': 'full',
        'geometries': 'geojson',
        'steps': includeSteps ? 'true' : 'false',
        'language': 'en',
        'access_token': accessToken,
      },
    );
    final response = await _http.get(uri).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      throw StateError('Mapbox route service failed (${response.statusCode}).');
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
      throw StateError('Mapbox returned an incomplete route.');
    }

    final steps = <QuickRideRouteStep>[];
    if (includeSteps) {
      final legs = route['legs'] as List<dynamic>? ?? const [];
      for (final rawLeg in legs) {
        if (rawLeg is! Map) continue;
        final rawSteps = rawLeg['steps'] as List<dynamic>? ?? const [];
        for (final raw in rawSteps) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          final maneuver = Map<String, dynamic>.from(item['maneuver'] as Map? ?? const {});
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

/// Lightweight controller shared by customer and driver map screens.
class QuickRideMapController {
  QuickRideMapController._(this._map);
  final fm.MapController _map;
  void moveTo(LatLng point, {double? zoom}) => _map.move(point, zoom ?? 15);
  void fitRoute(List<LatLng> points, {EdgeInsets padding = const EdgeInsets.fromLTRB(36, 175, 36, 250)}) {
    if (points.length < 2) return;
    _map.fitCamera(fm.CameraFit.coordinates(coordinates: points, padding: padding, maxZoom: 17));
  }
  void rotate(double degrees) => _map.rotate(degrees);
}

class QuickRideSearchResult {
  const QuickRideSearchResult({
    required this.mapboxId,
    required this.point,
    required this.name,
    required this.address,
    required this.resultType,
    this.sessionToken,
    this.postalCode,
  });

  final String mapboxId;
  final String? sessionToken;
  final LatLng point;
  final String name;
  final String address;
  final String resultType;
  final String? postalCode;
}

class QuickRidePlace {
  const QuickRidePlace({
    required this.point,
    required this.name,
    required this.address,
    this.postalCode,
  });

  final LatLng point;
  final String name;
  final String address;
  final String? postalCode;
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

class QuickRideMapView extends StatefulWidget {
  const QuickRideMapView({
    super.key, this.initialCenter, this.initialZoom = 13, this.showUserLocation = true,
    this.currentPosition, this.pickup, this.destination, this.routePoints = const [],
    this.onMapCreated, this.onTap, this.followCurrentPosition = false,
    this.navigationCamera = false, this.recenterSignal = 0,
    this.fitRouteBottomInset = 300, this.userAgentPackageName = 'com.quickride.customer',
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
  /// Stable application identifier used in requests to OpenStreetMap tile servers.
  final String userAgentPackageName;
  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  late final fm.MapController _mapController = fm.MapController();
  QuickRideMapController? _controller;
  bool _mapReady = false;
  LatLng get _initial => widget.currentPosition ?? widget.initialCenter ?? const LatLng(20.5937, 78.9629);

  void _onMapReady() {
    if (!mounted) return;
    _controller = QuickRideMapController._(_mapController);
    setState(() => _mapReady = true);
    widget.onMapCreated?.call(_controller!);
    if (widget.routePoints.length >= 2) {
      _controller!.fitRoute(widget.routePoints, padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset));
    }
  }

  List<fm.Marker> get _markers {
    final markers = <fm.Marker>[];
    if (widget.showUserLocation && widget.currentPosition != null) {
      markers.add(fm.Marker(
        point: widget.currentPosition!, width: 28, height: 28,
        child: Container(decoration: BoxDecoration(
          color: const Color(0xFF2463EB), shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 5)],
        )),
      ));
    }
    if (widget.pickup != null) {
      markers.add(fm.Marker(point: widget.pickup!, width: 40, height: 44,
        alignment: Alignment.topCenter,
        child: const Icon(Icons.location_on, size: 40, color: Color(0xFF159B65))));
    }
    if (widget.destination != null) {
      markers.add(fm.Marker(point: widget.destination!, width: 40, height: 44,
        alignment: Alignment.topCenter,
        child: const Icon(Icons.location_on, size: 40, color: Color(0xFFD94747))));
    }
    return markers;
  }

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldRecenter = widget.recenterSignal != oldWidget.recenterSignal ||
        (widget.followCurrentPosition && oldWidget.currentPosition != widget.currentPosition) ||
        widget.navigationCamera != oldWidget.navigationCamera;
    if (shouldRecenter) {
      final point = widget.currentPosition ?? widget.initialCenter;
      if (_mapReady && point != null) _controller?.moveTo(point, zoom: widget.navigationCamera ? 17 : 15.5);
    }
    if (!widget.navigationCamera && !listEquals(oldWidget.routePoints, widget.routePoints) &&
        widget.routePoints.length >= 2 && _mapReady) {
      _controller?.fitRoute(widget.routePoints,
        padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset));
    }
  }

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) return override(context, widget);
    return Stack(fit: StackFit.expand, children: [
      fm.FlutterMap(
        key: const ValueKey('quickRideOsmMap'),
        mapController: _mapController,
        options: fm.MapOptions(
          initialCenter: _initial, initialZoom: widget.initialZoom, maxZoom: 19,
          onTap: (tapPosition, point) => widget.onTap?.call(point),
          onMapReady: _onMapReady,
        ),
        children: [
          fm.TileLayer(
            urlTemplate: QuickRideMaps.tileUrl,
            userAgentPackageName: widget.userAgentPackageName,
            maxZoom: 19,
          ),
          if (widget.routePoints.length >= 2)
            fm.PolylineLayer(polylines: [fm.Polyline(
              points: widget.routePoints, color: const Color(0xFF2167D5), strokeWidth: 5,
            )]),
          if (_markers.isNotEmpty) fm.MarkerLayer(markers: _markers),
        ],
      ),
      Positioned(right: 8, bottom: 8, child: IgnorePointer(child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 3)],
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text('© Mapbox © OpenStreetMap contributors',
            style: TextStyle(fontSize: 10, color: Color(0xFF333333))),
        ),
      ))),
      if (!_mapReady) const IgnorePointer(child: Center(child: CircularProgressIndicator())),
    ]);
  }
}
