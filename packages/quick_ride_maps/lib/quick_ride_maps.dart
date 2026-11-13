import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
export 'package:latlong2/latlong.dart';

class _QuickRideCacheEntry {
  const _QuickRideCacheEntry({required this.value, required this.expiresAt});
  final Object? value;
  final DateTime expiresAt;
}

/// Test provider: OpenStreetMap tiles, Photon geocoding and OSRM routing.
/// The previous Mapbox implementation is preserved in quick_ride_maps_mapbox.dart.
class QuickRideMaps {
  QuickRideMaps._();
  static const String defaultLanguage = 'en';
  static const String accessToken = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static const String activeProvider = 'openstreetmap';
  static final http.Client _http = http.Client();
  static final Map<String, _QuickRideCacheEntry> _responseCache = {};
  static final Map<String, Future<dynamic>> _inFlightRequests = {};
  static bool get isConfigured => true;
  static void configure() {}
  static Widget Function(BuildContext context, QuickRideMapView view)? mapWidgetOverride;

  static Future<T> _remember<T>(String key, {required Duration ttl, required Future<T> Function() load}) async {
    final now = DateTime.now();
    final cached = _responseCache[key];
    if (cached != null && cached.expiresAt.isAfter(now)) return cached.value as T;
    if (cached != null) _responseCache.remove(key);
    final pending = _inFlightRequests[key];
    if (pending != null) return await pending as T;
    final future = load();
    _inFlightRequests[key] = future;
    try {
      final value = await future;
      _responseCache[key] = _QuickRideCacheEntry(value: value, expiresAt: DateTime.now().add(ttl));
      if (_responseCache.length > 250) {
        final expired = _responseCache.entries.where((e) => !e.value.expiresAt.isAfter(DateTime.now())).map((e) => e.key).toList();
        for (final key in expired) { _responseCache.remove(key); }
        while (_responseCache.length > 250) { _responseCache.remove(_responseCache.keys.first); }
      }
      return value;
    } finally {
      if (identical(_inFlightRequests[key], future)) _inFlightRequests.remove(key);
    }
  }

  static Future<geo.Position> currentPosition() => _remember('device-current-location',
    ttl: const Duration(seconds: 15), load: () async {
      if (!await geo.Geolocator.isLocationServiceEnabled()) throw StateError('Location services are disabled. Enable GPS and try again.');
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied || permission == geo.LocationPermission.deniedForever) {
        throw StateError('Location permission was not granted. You can still search for a pickup location.');
      }
      return geo.Geolocator.getCurrentPosition(locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
    });

  static Stream<geo.Position> watchDriverPosition() => geo.Geolocator.getPositionStream(
    locationSettings: geo.AndroidSettings(accuracy: geo.LocationAccuracy.high, distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const geo.ForegroundNotificationConfig(
        notificationTitle: 'Quick Ride Captain location',
        notificationText: 'Location is shared while you are online or completing a ride.',
        enableWakeLock: true)));

  static Future<List<QuickRideSearchResult>> searchSuggestions({
    required String query, LatLng? proximity, String language = defaultLanguage,
  }) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final key = 'photon:$text:${proximity?.latitude.toStringAsFixed(2)}:${proximity?.longitude.toStringAsFixed(2)}:$language';
    return _remember(key, ttl: const Duration(minutes: 3), load: () async {
      final uri = Uri.https('photon.komoot.io', '/api/', {
        'q': text, 'limit': '8', 'lang': language,
        if (proximity != null) 'lat': proximity.latitude.toString(),
        if (proximity != null) 'lon': proximity.longitude.toString(),
        'countrycode': 'in',
      });
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/geo+json',
        'User-Agent': 'QuickRide/0.1.0 (Android test application)',
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw StateError('Location search is temporarily unavailable (${response.statusCode}).');
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final features = payload['features'] as List<dynamic>? ?? const [];
      return features.whereType<Map>().map((raw) {
        final feature = Map<String, dynamic>.from(raw);
        final properties = Map<String, dynamic>.from(feature['properties'] as Map? ?? const {});
        final geometry = Map<String, dynamic>.from(feature['geometry'] as Map? ?? const {});
        final coordinates = geometry['coordinates'] as List<dynamic>? ?? const [];
        if (coordinates.length < 2 || coordinates[0] is! num || coordinates[1] is! num) return null;
        final name = (properties['name'] ?? properties['street'] ?? properties['city'] ?? properties['county'] ?? 'Location').toString();
        final address = _photonAddress(properties, name);
        return QuickRideSearchResult(
          mapboxId: '${properties['osm_type'] ?? 'osm'}:${properties['osm_id'] ?? ''}',
          point: LatLng((coordinates[1] as num).toDouble(), (coordinates[0] as num).toDouble()),
          name: name, address: address, resultType: (properties['type'] ?? '').toString(),
          postalCode: _postalCode(address) ?? properties['postcode']?.toString());
      }).whereType<QuickRideSearchResult>().toList(growable: false);
    });
  }

  static String _photonAddress(Map<String, dynamic> p, String name) {
    final values = <String?>[name, p['street']?.toString(), p['city']?.toString(),
      p['county']?.toString(), p['state']?.toString(), p['postcode']?.toString(), p['country']?.toString()];
    final parts = <String>[];
    for (final value in values) {
      final item = value?.trim();
      if (item != null && item.isNotEmpty && !parts.contains(item)) parts.add(item);
    }
    return parts.join(', ');
  }

  static Future<QuickRidePlace> retrieveSuggestion(QuickRideSearchResult suggestion) async {
    if (suggestion.point.latitude == 0 && suggestion.point.longitude == 0) {
      throw StateError('This search result has no coordinates. Search again and select a result.');
    }
    return QuickRidePlace(point: suggestion.point, name: suggestion.name,
      address: suggestion.address, postalCode: suggestion.postalCode);
  }

  static String? _postalCode(String value) => RegExp(r'(?<![0-9])[1-9][0-9]{5}(?![0-9])').firstMatch(value)?.group(0);

  static Future<String> reverseGeocode(LatLng point, {String language = defaultLanguage}) {
    final key = 'photon-reverse:${point.latitude.toStringAsFixed(5)}:${point.longitude.toStringAsFixed(5)}:$language';
    return _remember(key, ttl: const Duration(hours: 12), load: () async {
      final uri = Uri.https('photon.komoot.io', '/reverse', {
        'lat': point.latitude.toString(), 'lon': point.longitude.toString(), 'lang': language});
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/geo+json', 'User-Agent': 'QuickRide/0.1.0 (Android test application)',
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw StateError('Address lookup is temporarily unavailable (${response.statusCode}).');
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final features = payload['features'] as List<dynamic>? ?? const [];
      if (features.isEmpty || features.first is! Map) {
        return 'Selected location (${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})';
      }
      final p = Map<String, dynamic>.from((features.first as Map)['properties'] as Map? ?? const {});
      final name = (p['name'] ?? p['street'] ?? p['city'] ?? 'Selected location').toString();
      return _photonAddress(p, name);
    });
  }

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin, required LatLng destination, bool includeSteps = false,
  }) {
    final key = 'osrm:${origin.latitude.toStringAsFixed(5)}:${origin.longitude.toStringAsFixed(5)}:${destination.latitude.toStringAsFixed(5)}:${destination.longitude.toStringAsFixed(5)}:$includeSteps';
    return _remember(key, ttl: const Duration(minutes: 5), load: () async {
      final coordinates = '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
      final uri = Uri.https('router.project-osrm.org', '/route/v1/driving/$coordinates', {
        'alternatives': 'false', 'overview': 'full', 'geometries': 'geojson',
        'steps': includeSteps ? 'true' : 'false'});
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/json', 'User-Agent': 'QuickRide/0.1.0 (Android test application)',
      }).timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) throw StateError('Route service is temporarily unavailable (${response.statusCode}).');
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      if (payload['code'] != 'Ok') throw StateError((payload['message'] ?? 'No drivable route found.').toString());
      final routes = payload['routes'] as List<dynamic>? ?? const [];
      if (routes.isEmpty || routes.first is! Map) throw StateError('No drivable route was returned for these locations.');
      final route = Map<String, dynamic>.from(routes.first as Map);
      final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
      final raw = geometry['coordinates'] as List<dynamic>? ?? const [];
      final points = raw.whereType<List<dynamic>>().where((p) => p.length >= 2 && p[0] is num && p[1] is num)
        .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble())).toList(growable: false);
      if (points.length < 2) throw StateError('The route service returned an incomplete route.');
      final steps = <QuickRideRouteStep>[];
      if (includeSteps) {
        for (final rawLeg in (route['legs'] as List<dynamic>? ?? const [])) {
          if (rawLeg is! Map) continue;
          for (final rawStep in (rawLeg['steps'] as List<dynamic>? ?? const [])) {
            if (rawStep is! Map) continue;
            final item = Map<String, dynamic>.from(rawStep);
            final maneuver = Map<String, dynamic>.from(item['maneuver'] as Map? ?? const {});
            final location = maneuver['location'] as List<dynamic>? ?? const [];
            steps.add(QuickRideRouteStep(
              instruction: _osrmInstruction((maneuver['type'] ?? '').toString(),
                maneuver['modifier']?.toString(), (item['name'] ?? '').toString(),
                (maneuver['exit'] as num?)?.toInt()),
              location: location.length >= 2 && location[0] is num && location[1] is num
                ? LatLng((location[1] as num).toDouble(), (location[0] as num).toDouble()) : null,
              distanceMeters: (item['distance'] as num?)?.toDouble() ?? 0,
              durationSeconds: (item['duration'] as num?)?.toDouble() ?? 0));
          }
        }
      }
      return QuickRideRoute(points: points, distanceMeters: (route['distance'] as num).toDouble(),
        durationSeconds: (route['duration'] as num).toDouble(), steps: steps);
    });
  }

  static String _osrmInstruction(String type, String? modifier, String road, int? exit) {
    final name = road.trim().isEmpty ? 'the road' : road.trim();
    switch (type) {
      case 'depart': return 'Start on $name';
      case 'arrive': return 'You have arrived at your destination';
      case 'roundabout':
      case 'rotary': return exit == null ? 'Enter the roundabout and continue on $name' : 'At the roundabout, take exit $exit onto $name';
      case 'merge': return 'Merge ${modifier ?? ''} onto $name'.replaceAll(RegExp(r'\s+'), ' ').trim();
      case 'on ramp':
      case 'on_ramp': return 'Take the ramp onto $name';
      case 'off ramp':
      case 'off_ramp': return 'Take the exit toward $name';
      case 'turn':
      case 'end of road':
      case 'end_of_road': return 'Turn ${modifier ?? ''} onto $name'.replaceAll(RegExp(r'\s+'), ' ').trim();
      case 'continue':
      case 'new name':
      case 'new_name': return 'Continue on $name';
      default: return 'Continue on $name';
    }
  }
}

class QuickRideMapController {
  QuickRideMapController._(this._map);
  final fm.MapController _map;
  void moveTo(LatLng point, {double? zoom}) {
    try { _map.move(point, zoom ?? 15); } catch (_) {}
  }
  void fitRoute(List<LatLng> points, {EdgeInsets padding = const EdgeInsets.fromLTRB(36, 175, 36, 250)}) {
    if (points.length < 2) return;
    try { _map.fitCamera(fm.CameraFit.bounds(bounds: fm.LatLngBounds.fromPoints(points), padding: padding)); } catch (_) {}
  }
  /// OSM test maps remain north-up; Mapbox bearing returns with the Mapbox provider.
  void rotate(double degrees) {}
}

class QuickRideSearchResult {
  const QuickRideSearchResult({required this.mapboxId, required this.point, required this.name,
    required this.address, required this.resultType, this.sessionToken, this.postalCode});
  final String mapboxId;
  final String? sessionToken;
  final LatLng point;
  final String name;
  final String address;
  final String resultType;
  final String? postalCode;
}
class QuickRidePlace {
  const QuickRidePlace({required this.point, required this.name, required this.address, this.postalCode});
  final LatLng point;
  final String name;
  final String address;
  final String? postalCode;
}
class QuickRideRoute {
  const QuickRideRoute({required this.points, required this.distanceMeters, required this.durationSeconds, this.steps = const []});
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<QuickRideRouteStep> steps;
}
class QuickRideRouteStep {
  const QuickRideRouteStep({required this.instruction, required this.location, required this.distanceMeters, required this.durationSeconds});
  final String instruction;
  final LatLng? location;
  final double distanceMeters;
  final double durationSeconds;
}

class QuickRideMapView extends StatefulWidget {
  const QuickRideMapView({super.key, this.initialCenter, this.initialZoom = 13,
    this.showUserLocation = true, this.currentPosition, this.cameraTarget, this.pickup,
    this.destination, this.routePoints = const [], this.onMapCreated, this.onTap,
    this.followCurrentPosition = false, this.navigationCamera = false,
    this.recenterSignal = 0, this.fitRouteBottomInset = 300,
    this.userAgentPackageName = 'com.quickride.customer'});
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
  final String userAgentPackageName;
  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  late final fm.MapController _map;
  QuickRideMapController? _controller;
  bool _mapReady = false;
  LatLng get _initial => widget.currentPosition ?? widget.initialCenter ?? const LatLng(25.4358, 81.8463);

  @override
  void initState() { super.initState(); _map = fm.MapController(); }

  void _onMapReady() {
    if (!mounted || _mapReady) return;
    _controller = QuickRideMapController._(_map);
    setState(() => _mapReady = true);
    widget.onMapCreated?.call(_controller!);
    final target = widget.cameraTarget ?? widget.currentPosition;
    if (target != null) {
      _controller!.moveTo(target, zoom: widget.navigationCamera ? 17 : 15);
    } else if (widget.routePoints.length >= 2) {
      _controller!.fitRoute(widget.routePoints, padding: EdgeInsets.fromLTRB(36, 100, 36, widget.fitRouteBottomInset));
    }
  }

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_mapReady) return;
    final routeChanged = !listEquals(oldWidget.routePoints, widget.routePoints);
    final positionChanged = oldWidget.currentPosition != widget.currentPosition;
    final targetChanged = oldWidget.cameraTarget != widget.cameraTarget;
    final recenter = oldWidget.recenterSignal != widget.recenterSignal;
    final navigationChanged = oldWidget.navigationCamera != widget.navigationCamera;
    if (recenter || targetChanged || (positionChanged && widget.followCurrentPosition) || navigationChanged) {
      final point = widget.cameraTarget ?? widget.currentPosition ?? widget.initialCenter;
      if (point != null) _controller?.moveTo(point, zoom: widget.navigationCamera ? 17 : 15.5);
    } else if (routeChanged && !widget.navigationCamera && widget.routePoints.length >= 2) {
      _controller?.fitRoute(widget.routePoints, padding: EdgeInsets.fromLTRB(36, 100, 36, widget.fitRouteBottomInset));
    }
  }

  List<fm.Marker> _markers() {
    final markers = <fm.Marker>[];
    void pin(LatLng? point, Color color) {
      if (point == null) return;
      markers.add(fm.Marker(point: point, width: 42, height: 48, alignment: Alignment.bottomCenter,
        child: Icon(Icons.location_on_rounded, color: color, size: 38,
          shadows: const [Shadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 2))])));
    }
    if (widget.showUserLocation && widget.currentPosition != null) {
      markers.add(fm.Marker(point: widget.currentPosition!, width: 24, height: 24,
        child: Container(decoration: BoxDecoration(color: const Color(0xFF2463EB),
          shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)]))));
    }
    pin(widget.pickup, const Color(0xFF159B65));
    pin(widget.destination, const Color(0xFFD94747));
    return markers;
  }

  @override
  void dispose() { _map.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) return override(context, widget);
    return Stack(fit: StackFit.expand, children: [
      fm.FlutterMap(mapController: _map, options: fm.MapOptions(
        initialCenter: _initial, initialZoom: widget.initialZoom, minZoom: 3, maxZoom: 19,
        onTap: (_, point) => widget.onTap?.call(point), onMapReady: _onMapReady),
        children: [
          fm.TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: widget.userAgentPackageName, maxNativeZoom: 19, maxZoom: 19, keepBuffer: 2),
          if (widget.routePoints.length >= 2) fm.PolylineLayer(polylines: [
            fm.Polyline(points: widget.routePoints, strokeWidth: 5, color: const Color(0xFF2167D5),
              borderStrokeWidth: 1.5, borderColor: Colors.white)]),
          fm.MarkerLayer(markers: _markers()),
          fm.RichAttributionWidget(attributions: const [
            fm.TextSourceAttribution('© OpenStreetMap contributors')]),
        ]),
      if (!_mapReady) const IgnorePointer(child: Center(child: CircularProgressIndicator())),
    ]);
  }
}
