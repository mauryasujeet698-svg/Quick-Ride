import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;

export 'package:latlong2/latlong.dart';

class _QuickRideCacheEntry {
  const _QuickRideCacheEntry({
    required this.value,
    required this.expiresAt,
  });

  final Object? value;
  final DateTime expiresAt;
}

/// Mapbox-backed location search, address lookup, routing and native map view.
class QuickRideMaps {
  QuickRideMaps._();

  static const String defaultLanguage = 'en';
  static const String accessToken = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static final http.Client _http = http.Client();
  static final Random _random = Random.secure();

  // Keep recently used location and route responses in memory so tab changes,
  // repeated selections and rebuilds do not trigger duplicate network calls.
  static final Map<String, _QuickRideCacheEntry> _responseCache = {};
  static final Map<String, Future<dynamic>> _inFlightRequests = {};

  static Future<T> _remember<T>(
    String key, {
    required Duration ttl,
    required Future<T> Function() load,
  }) async {
    final now = DateTime.now();
    final cached = _responseCache[key];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.value as T;
    }
    if (cached != null) _responseCache.remove(key);

    final pending = _inFlightRequests[key];
    if (pending != null) return await pending as T;

    final future = load();
    _inFlightRequests[key] = future;
    try {
      final value = await future;
      _responseCache[key] = _QuickRideCacheEntry(
        value: value,
        expiresAt: DateTime.now().add(ttl),
      );
      if (_responseCache.length > 250) {
        final expiredKeys = _responseCache.entries
            .where((entry) => !entry.value.expiresAt.isAfter(DateTime.now()))
            .map((entry) => entry.key)
            .toList(growable: false);
        for (final expiredKey in expiredKeys) {
          _responseCache.remove(expiredKey);
        }
        while (_responseCache.length > 250) {
          _responseCache.remove(_responseCache.keys.first);
        }
      }
      return value;
    } finally {
      if (identical(_inFlightRequests[key], future)) {
        _inFlightRequests.remove(key);
      }
    }
  }
  static String? _activeSearchSessionToken;
  static DateTime? _searchSessionStartedAt;
  static bool _configured = false;

  /// Allows widget tests to replace the native map canvas. Production leaves this null.
  static Widget Function(BuildContext context, QuickRideMapView view)?
      mapWidgetOverride;

  static String get _normalizedAccessToken => accessToken.trim();

  static bool get isConfigured => _normalizedAccessToken.startsWith('pk.');

  static void configure() {
    if (_configured || !isConfigured) return;
    // Set the token through Mapbox's native SDK before any MapWidget is created.
    mb.MapboxOptions.setAccessToken(_normalizedAccessToken);
    _configured = true;
  }

  static void _requireToken() {
    if (!isConfigured) {
      throw StateError(
        'Mapbox is not configured. Add a public Mapbox token (pk.*) to the MAPBOX_ACCESS_TOKEN build secret.',
      );
    }
    configure();
  }

  static Future<geo.Position> currentPosition() => _remember(
        'device-current-location',
        ttl: const Duration(seconds: 20),
        load: () async {
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
        },
      );

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
  }) {
    final key = 'reverse:${point.latitude.toStringAsFixed(5)}:${point.longitude.toStringAsFixed(5)}:$language';
    return _remember(
      key,
      ttl: const Duration(hours: 12),
      load: () async {
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
          throw StateError('Mapbox address lookup failed (${response.statusCode}).');
        }
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final features = payload['features'] as List<dynamic>? ?? const [];
        if (features.isEmpty || features.first is! Map) {
          return 'Selected location (${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})';
        }
        final properties = Map<String, dynamic>.from(
          (features.first as Map)['properties'] as Map? ?? const {},
        );
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
            RegExp(r'^[1-9][0-9]{5}$').hasMatch(postcode) &&
            !address.contains(postcode)) {
          return '$address, $postcode';
        }
        return address;
      },
    );
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) {
    final key = 'route:${origin.latitude.toStringAsFixed(5)}:${origin.longitude.toStringAsFixed(5)}:${destination.latitude.toStringAsFixed(5)}:${destination.longitude.toStringAsFixed(5)}:$includeSteps';
    return _remember(
      key,
      ttl: const Duration(minutes: 5),
      load: () async {
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
      },
    );
  }

}

/// Native Mapbox map controller shared by customer and driver screens.
class QuickRideMapController {
  QuickRideMapController._(this._map);

  final mb.MapboxMap _map;

  void moveTo(LatLng point, {double? zoom}) {
    unawaited(_map.flyTo(
      mb.CameraOptions(
        center: mb.Point(
          coordinates: mb.Position(point.longitude, point.latitude),
        ),
        zoom: zoom,
      ),
      mb.MapAnimationOptions(duration: 350),
    ));
  }

  void fitRoute(
    List<LatLng> points, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(36, 175, 36, 250),
  }) {
    if (points.length < 2) return;
    unawaited(() async {
      final camera = await _map.cameraForCoordinates(
        points
            .map((point) => mb.Point(
                  coordinates: mb.Position(point.longitude, point.latitude),
                ))
            .toList(growable: false),
        mb.MbxEdgeInsets(
          top: padding.top,
          left: padding.left,
          bottom: padding.bottom,
          right: padding.right,
        ),
        null,
        null,
      );
      await _map.flyTo(camera, mb.MapAnimationOptions(duration: 450));
    }());
  }

  void rotate(double degrees) {
    unawaited(_map.flyTo(
      mb.CameraOptions(bearing: degrees),
      mb.MapAnimationOptions(duration: 300),
    ));
  }
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
    super.key,
    this.initialCenter,
    this.initialZoom = 13,
    this.showUserLocation = true,
    this.currentPosition,
    this.cameraTarget,
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
  final LatLng? cameraTarget;
  final LatLng? pickup;
  final LatLng? destination;
  final List<LatLng> routePoints;
  final ValueChanged<QuickRideMapController>? onMapCreated;
  final ValueChanged<LatLng>? onTap;
  final bool followCurrentPosition;
  final bool navigationCamera;
  final int recenterSignal;
  final double fitRouteBottomInset;

  /// Retained for source compatibility with existing map call sites.
  final String userAgentPackageName;

  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  mb.CircleAnnotationManager? _markerManager;
  mb.PolylineAnnotationManager? _routeManager;
  QuickRideMapController? _controller;
  bool _mapReady = false;
  bool _styleLoaded = false;
  bool _syncing = false;
  bool _syncAgain = false;
  String? _mapError;
  int _mapInstanceKey = 0;

  LatLng get _initial =>
      widget.currentPosition ?? widget.initialCenter ?? const LatLng(25.4358, 81.8463);

  @override
  void initState() {
    super.initState();
    QuickRideMaps.configure();
  }

  Future<void> _onMapCreated(mb.MapboxMap map) async {
    _controller = QuickRideMapController._(map);

    map.addInteraction(mb.TapInteraction.onMap((context) {
      final coordinate = context.point.coordinates;
      widget.onTap?.call(LatLng(coordinate.lat.toDouble(), coordinate.lng.toDouble()));
    }));

    try {
      _markerManager = await map.annotations.createCircleAnnotationManager();
      _routeManager = await map.annotations.createPolylineAnnotationManager();
      if (!mounted) return;
      setState(() => _mapReady = true);
      widget.onMapCreated?.call(_controller!);
      if (_styleLoaded) {
        await _syncMap();
      }
    } catch (error) {
      _setMapError(error);
    }
  }

  void _onStyleLoaded(mb.StyleLoadedEventData event) {
    _styleLoaded = true;
    if (!mounted) return;
    setState(() => _mapError = null);
    unawaited(_syncMap());
  }

  void _onMapLoadError(dynamic event) {
    if (!mounted) return;
    // Never surface raw native SDK errors; they may contain request URLs or configuration details.
    debugPrint('Quick Ride map resource load failed (' + event.runtimeType.toString() + ').');
    setState(() {
      _mapError = 'Map temporarily unavailable. Check your connection and retry.';
    });
  }

  void _retryMap() {
    if (!mounted) return;
    setState(() {
      _mapError = null;
      _mapReady = false;
      _styleLoaded = false;
      _markerManager = null;
      _routeManager = null;
      _controller = null;
      _syncing = false;
      _syncAgain = false;
      _mapInstanceKey++;
    });
  }

  void _setMapError(Object error) {
    if (!mounted) return;
    setState(() {
      _mapError = 'Map temporarily unavailable. Check your connection and retry.';
    });
    debugPrint('Quick Ride native Mapbox initialization failed (' + error.runtimeType.toString() + ').');
  }

  Future<void> _syncMap() async {
    if (!_mapReady || !_styleLoaded) return;
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    do {
      _syncAgain = false;
      try {
        final markers = _markerManager;
        final route = _routeManager;
        if (markers == null || route == null) {
          throw StateError('Native Mapbox annotation managers are not ready.');
        }

        await markers.deleteAll();
        final markerOptions = <mb.CircleAnnotationOptions>[];
        void addMarker(LatLng? point, Color color, double radius) {
          if (point == null) return;
          markerOptions.add(mb.CircleAnnotationOptions(
            geometry: mb.Point(
              coordinates: mb.Position(point.longitude, point.latitude),
            ),
            circleRadius: radius,
            circleColor: color.toARGB32(),
            circleStrokeColor: Colors.white.toARGB32(),
            circleStrokeWidth: 2,
          ));
        }

        final location = widget.showUserLocation ? widget.currentPosition : null;
        if (location != null) {
          // Ola-style anchored locator: a green pin head, a short dark stem,
          // and the blue current-position dot. All are map annotations, so
          // they stay attached to the geographic location while panning/zooming.
          final pinHead = LatLng(location.latitude + 0.00010, location.longitude);
          addMarker(pinHead, const Color(0xFF159B65), 8);
          addMarker(location, const Color(0xFF2463EB), 5);
          await route.create(mb.PolylineAnnotationOptions(
            geometry: mb.LineString(
              coordinates: [
                mb.Position(location.longitude, location.latitude),
                mb.Position(pinHead.longitude, pinHead.latitude),
              ],
            ),
            lineColor: const Color(0xFF263238).toARGB32(),
            lineWidth: 2.5,
          ));
        } else {
          addMarker(widget.pickup, const Color(0xFF159B65), 8);
        }
        addMarker(widget.destination, const Color(0xFFD94747), 8);
        if (markerOptions.isNotEmpty) {
          await markers.createMulti(markerOptions);
        }

        if (widget.routePoints.length >= 2) {
          await route.create(mb.PolylineAnnotationOptions(
            geometry: mb.LineString(
              coordinates: widget.routePoints
                  .map((point) => mb.Position(point.longitude, point.latitude))
                  .toList(growable: false),
            ),
            lineColor: const Color(0xFF2167D5).toARGB32(),
            lineWidth: 5,
          ));
        }
      } catch (error) {
        _setMapError(error);
      }
    } while (_syncAgain && mounted);
    _syncing = false;
  }

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    final mapDataChanged =
        !listEquals(oldWidget.routePoints, widget.routePoints) ||
        oldWidget.currentPosition != widget.currentPosition ||
        oldWidget.cameraTarget != widget.cameraTarget ||
        oldWidget.pickup != widget.pickup ||
        oldWidget.destination != widget.destination ||
        oldWidget.showUserLocation != widget.showUserLocation;

    if (mapDataChanged) {
      unawaited(_syncMap());
    }

    final shouldRecenter =
        widget.recenterSignal != oldWidget.recenterSignal ||
        (widget.followCurrentPosition &&
            oldWidget.currentPosition != widget.currentPosition) ||
        widget.navigationCamera != oldWidget.navigationCamera;
    if (shouldRecenter) {
      final point = widget.cameraTarget ?? widget.currentPosition ?? widget.initialCenter;
      if (point != null) {
        _controller?.moveTo(point, zoom: widget.navigationCamera ? 17 : 15.5);
      }
    }

    if (!widget.navigationCamera &&
        !listEquals(oldWidget.routePoints, widget.routePoints) &&
        widget.routePoints.length >= 2) {
      _controller?.fitRoute(
        widget.routePoints,
        padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) {
      return override(context, widget);
    }

    if (!QuickRideMaps.isConfigured) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Map service is not configured. Please contact support.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        mb.MapWidget(
          key: ValueKey('quickRideNativeMap_' + _mapInstanceKey.toString()),
          styleUri: mb.MapboxStyles.MAPBOX_STREETS,
          viewport: mb.CameraViewportState(
            center: mb.Point(
              coordinates: mb.Position(_initial.longitude, _initial.latitude),
            ),
            zoom: widget.initialZoom,
          ),
          onMapCreated: _onMapCreated,
          onStyleLoadedListener: _onStyleLoaded,
          onMapLoadErrorListener: _onMapLoadError,
          textureView: true,
        ),
        if (!_mapReady && _mapError == null)
          const IgnorePointer(
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_mapError != null)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Material(
              elevation: 2,
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _mapError!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _retryMap,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry map'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
