import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CustomerRideTrackingScreen extends StatefulWidget {
  const CustomerRideTrackingScreen({super.key, required this.rideId});

  final String rideId;

  @override
  State<CustomerRideTrackingScreen> createState() => _CustomerRideTrackingScreenState();
}

class _CustomerRideTrackingScreenState extends State<CustomerRideTrackingScreen> {
  final _environment = QuickRideEnvironment.fromBuildDefines();

  MapboxMap? _map;
  CircleAnnotationManager? _circleManager;
  PolylineAnnotationManager? _routeManager;
  PolylineAnnotation? _routeAnnotation;
  CircleAnnotation? _pickupAnnotation;
  CircleAnnotation? _destinationAnnotation;
  CircleAnnotation? _driverAnnotation;
  RealtimeChannel? _rideChangesChannel;
  RealtimeChannel? _driverLocationChannel;
  String? _subscribedDriverId;
  Timer? _refreshTimer;
  Map<String, dynamic>? _tracking;
  bool _loading = true;
  bool _refreshing = false;
  bool _cameraInitialized = false;
  bool _routeRequestInFlight = false;
  DateTime _lastRouteFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastRouteStatus;
  Position? _lastRouteOrigin;
  double? _routeDistanceMeters;
  double? _routeDurationSeconds;
  String? _error;

  Map<String, dynamic>? get _ride =>
      _tracking?['ride'] is Map
          ? Map<String, dynamic>.from(_tracking!['ride'] as Map)
          : null;

  Map<String, dynamic>? get _driver =>
      _tracking?['driver'] is Map
          ? Map<String, dynamic>.from(_tracking!['driver'] as Map)
          : null;

  Map<String, dynamic>? get _driverLocation =>
      _driver?['location'] is Map
          ? Map<String, dynamic>.from(_driver!['location'] as Map)
          : null;

  String? get _driverId => _driver?['id']?.toString();

  bool get _driverLocationIsStale {
    final recordedAt = DateTime.tryParse(_driverLocation?['recorded_at']?.toString() ?? '');
    if (recordedAt == null) return true;
    return DateTime.now().toUtc().difference(recordedAt.toUtc()) >
        const Duration(seconds: 45);
  }

  bool get _active => const {
        'requested',
        'searching',
        'offered',
        'accepted',
        'driver_arriving',
        'arrived',
        'in_progress',
      }.contains(_ride?['status']);

  @override
  void initState() {
    super.initState();
    _ensureRideChangesSubscription();
    unawaited(_refresh());
    // Realtime is the primary update path. This slower poll repairs missed
    // events after a short connection interruption or app resume.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_active) {
        unawaited(_refresh(silent: true));
      } else {
        _refreshTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    final rideChannel = _rideChangesChannel;
    final driverChannel = _driverLocationChannel;
    if (QuickRideBackend.isInitialized && rideChannel != null) {
      unawaited(QuickRideBackend.client.removeChannel(rideChannel).then<void>((_) {}));
    }
    if (QuickRideBackend.isInitialized && driverChannel != null) {
      unawaited(QuickRideBackend.client.removeChannel(driverChannel).then<void>((_) {}));
    }
    super.dispose();
  }

  void _ensureRideChangesSubscription() {
    if (!QuickRideBackend.isInitialized ||
        QuickRideAuth.currentUser == null ||
        _rideChangesChannel != null) {
      return;
    }
    _rideChangesChannel = QuickRideBackend.client
        .channel('customer-ride-${widget.rideId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'rides',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: widget.rideId,
          ),
          callback: (_) => unawaited(_refresh(silent: true)),
        )
        .subscribe();
  }

  Future<void> _syncDriverLocationSubscription() async {
    final driverId = _active ? _driverId : null;
    if (driverId == _subscribedDriverId) return;

    final previous = _driverLocationChannel;
    _driverLocationChannel = null;
    _subscribedDriverId = null;
    if (previous != null) {
      await QuickRideBackend.client.removeChannel(previous);
    }
    if (driverId == null || !QuickRideBackend.isInitialized) return;

    _subscribedDriverId = driverId;
    _driverLocationChannel = QuickRideBackend.client
        .channel('customer-driver-location-${widget.rideId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'driver_locations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'driver_id',
            value: driverId,
          ),
          callback: (_) => unawaited(_refresh(silent: true)),
        )
        .subscribe();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Sign in to view ride tracking.';
        });
      }
      return;
    }
    if (_refreshing) return;
    _refreshing = true;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await QuickRideBackend.client.rpc(
        'get_customer_ride_tracking',
        params: {'p_ride_id': widget.rideId},
      );
      final data = Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      setState(() {
        _tracking = data;
        _loading = false;
        _error = null;
      });
      _ensureRideChangesSubscription();
      await _syncDriverLocationSubscription();
      await _syncMap();
      if (!_active) _refreshTimer?.cancel();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    } finally {
      _refreshing = false;
    }
  }

  Map<String, dynamic>? _asPoint(dynamic value) {
    if (value is! Map) return null;
    final point = Map<String, dynamic>.from(value);
    final longitude = point['longitude'];
    final latitude = point['latitude'];
    if (longitude is! num || latitude is! num) return null;
    if (!longitude.isFinite || !latitude.isFinite) return null;
    return {
      'longitude': longitude.toDouble(),
      'latitude': latitude.toDouble(),
    };
  }

  Position? _position(dynamic value) {
    final point = _asPoint(value);
    if (point == null) return null;
    return Position(
      point['longitude'] as double,
      point['latitude'] as double,
    );
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    try {
      _circleManager = await map.annotations.createCircleAnnotationManager();
      _routeManager = await map.annotations.createPolylineAnnotationManager();
      await _syncMap();
    } catch (error) {
      if (mounted) setState(() => _error = 'The tracking map could not be initialized: ' + error.toString());
    }
  }

  Future<CircleAnnotation> _upsertCircle(
    CircleAnnotation? existing,
    CircleAnnotationOptions options,
  ) async {
    final manager = _circleManager!;
    if (existing == null) return manager.create(options);
    existing.geometry = options.geometry;
    await manager.update(existing);
    return existing;
  }

  Future<void> _syncMap() async {
    final manager = _circleManager;
    final tracking = _tracking;
    if (manager == null || tracking == null) return;

    final ride = Map<String, dynamic>.from(tracking['ride'] as Map);
    final driver = tracking['driver'] is Map
        ? Map<String, dynamic>.from(tracking['driver'] as Map)
        : null;
    final pickup = _position(ride['pickup']);
    final destination = _position(ride['destination']);
    final driverLocation = driver == null ? null : _position(driver['location']);

    if (pickup != null) {
      _pickupAnnotation = await _upsertCircle(
        _pickupAnnotation,
        CircleAnnotationOptions(
          geometry: Point(coordinates: pickup),
          circleColor: Colors.green.toARGB32(),
          circleRadius: 9,
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 2,
        ),
      );
    }
    if (destination != null) {
      _destinationAnnotation = await _upsertCircle(
        _destinationAnnotation,
        CircleAnnotationOptions(
          geometry: Point(coordinates: destination),
          circleColor: Colors.red.toARGB32(),
          circleRadius: 9,
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 2,
        ),
      );
    }
    if (driverLocation != null) {
      _driverAnnotation = await _upsertCircle(
        _driverAnnotation,
        CircleAnnotationOptions(
          geometry: Point(coordinates: driverLocation),
          circleColor: Colors.blue.toARGB32(),
          circleRadius: 11,
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 3,
        ),
      );
    } else if (_driverAnnotation != null) {
      await manager.delete(_driverAnnotation!);
      _driverAnnotation = null;
    }

    unawaited(_refreshRouteIfNeeded(ride, driver, pickup, destination, driverLocation));

    if (!_cameraInitialized) {
      final center = driverLocation ?? pickup ?? destination;
      if (center != null) {
        await _map?.setCamera(CameraOptions(
          center: Point(coordinates: center),
          zoom: 14,
        ));
        _cameraInitialized = true;
      }
    }
  }


  double _distanceMeters(Position a, Position b) {
    const earthRadius = 6371000.0;
    final lat1 = a.lat * 0.017453292519943295;
    final lat2 = b.lat * 0.017453292519943295;
    final dLat = (b.lat - a.lat) * 0.017453292519943295;
    final dLng = (b.lng - a.lng) * 0.017453292519943295;
    final sinLat = (dLat / 2).abs();
    final sinLng = (dLng / 2).abs();
    final haversine = sinLat * sinLat +
        (lat1.cos() * lat2.cos() * sinLng * sinLng);
    final clamped = haversine.clamp(0.0, 1.0);
    return earthRadius * 2 * math.asin(math.sqrt(clamped));
  }

  Future<void> _refreshRouteIfNeeded(
    Map<String, dynamic> ride,
    Map<String, dynamic>? driver,
    Position? pickup,
    Position? destination,
    Position? driverLocation,
  ) async {
    final routeManager = _routeManager;
    if (routeManager == null || _routeRequestInFlight || pickup == null || destination == null) {
      return;
    }
    final status = ride['status']?.toString() ?? '';
    final origin = driverLocation ?? pickup;
    final target = status == 'in_progress' ? destination : (driverLocation == null ? destination : pickup);
    final now = DateTime.now();
    final statusChanged = status != _lastRouteStatus;
    final originMoved = _lastRouteOrigin == null ||
        _distanceMeters(_lastRouteOrigin!, origin) >= 150;
    final intervalElapsed = now.difference(_lastRouteFetchedAt) >= const Duration(seconds: 30);
    if (!statusChanged && !originMoved && !intervalElapsed) return;

    final token = _environment.mapboxPublicToken;
    if (!token.startsWith('pk.')) return;
    _routeRequestInFlight = true;
    _lastRouteFetchedAt = now;
    _lastRouteStatus = status;
    _lastRouteOrigin = origin;

    try {
      final coordinates = '${origin.lng},${origin.lat};${target.lng},${target.lat}';
      final uri = Uri.https(
        'api.mapbox.com',
        '/directions/v5/mapbox/driving/$coordinates',
        {
          'access_token': token,
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'false',
          'alternatives': 'false',
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw StateError('Mapbox route service returned ${response.statusCode}.');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = payload['routes'] as List<dynamic>? ?? [];
      if (routes.isEmpty) throw StateError('No route is available for this ride.');
      final route = Map<String, dynamic>.from(routes.first as Map);
      final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
      final rawCoordinates = geometry['coordinates'] as List<dynamic>? ?? [];
      final positions = rawCoordinates
          .whereType<List<dynamic>>()
          .where((pair) => pair.length >= 2 && pair[0] is num && pair[1] is num)
          .map((pair) => Position(
                (pair[0] as num).toDouble(),
                (pair[1] as num).toDouble(),
              ))
          .toList();
      if (positions.length < 2) throw StateError('Mapbox returned an incomplete route.');

      final annotationOptions = PolylineAnnotationOptions(
        geometry: LineString(coordinates: positions),
        lineColor: Colors.blue.toARGB32(),
        lineWidth: 6,
        lineBorderColor: Colors.white.toARGB32(),
        lineBorderWidth: 2,
        lineJoin: LineJoin.round,
      );
      final existing = _routeAnnotation;
      if (existing == null) {
        _routeAnnotation = await routeManager.create(annotationOptions);
      } else {
        existing.geometry = annotationOptions.geometry;
        await routeManager.update(existing);
      }
      if (!mounted) return;
      setState(() {
        _routeDistanceMeters = (route['distance'] as num?)?.toDouble();
        _routeDurationSeconds = (route['duration'] as num?)?.toDouble();
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Route/ETA temporarily unavailable: $error');
      }
    } finally {
      _routeRequestInFlight = false;
    }
  }

  String _formatRouteDistance() {
    final meters = _routeDistanceMeters;
    if (meters == null) return '—';
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  String _formatRouteEta() {
    final seconds = _routeDurationSeconds;
    if (seconds == null) return '—';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }

  Future<void> _centerOnDriver() async {
    final point = _position(_driverLocation) ??
        _position(_ride?['pickup']) ??
        _position(_ride?['destination']);
    if (point == null) return;
    await _map?.flyTo(
      CameraOptions(center: Point(coordinates: point), zoom: 15),
      MapAnimationOptions(duration: 700),
    );
  }

  String _statusLabel(String status) =>
      status.replaceAll('_', ' ').split(' ').map((part) {
        if (part.isEmpty) return part;
        return part[0].toUpperCase() + part.substring(1);
      }).join(' ');

  @override
  Widget build(BuildContext context) {
    final ride = _ride;
    final driver = _driver;
    final location = _driverLocation;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Track your ride'),
        actions: [
          IconButton(
            tooltip: 'Refresh ride status',
            onPressed: _loading ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && ride == null
          ? const Center(child: CircularProgressIndicator())
          : ride == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error ?? 'Ride details are unavailable.'),
                  ),
                )
              : Column(
                  children: [
                    if (_environment.mapboxConfigured)
                      SizedBox(
                        height: 290,
                        child: Stack(
                          children: [
                            MapWidget(
                              key: ValueKey('ride-tracking-' + widget.rideId),
                              viewport: CameraViewportState(
                                center: Point(coordinates: Position(78.9629, 20.5937)),
                                zoom: 4.5,
                              ),
                              onMapCreated: _onMapCreated,
                            ),
                            Positioned(
                              right: 14,
                              bottom: 14,
                              child: FloatingActionButton.small(
                                heroTag: 'center-ride-map',
                                onPressed: _centerOnDriver,
                                child: const Icon(Icons.my_location),
                              ),
                            ),
                            const Positioned(
                              left: 14,
                              top: 14,
                              child: Chip(
                                avatar: Icon(Icons.circle, color: Colors.green, size: 11),
                                label: Text('Pickup'),
                                backgroundColor: Colors.white,
                              ),
                            ),
                            const Positioned(
                              left: 105,
                              top: 14,
                              child: Chip(
                                avatar: Icon(Icons.circle, color: Colors.red, size: 11),
                                label: Text('Destination'),
                                backgroundColor: Colors.white,
                              ),
                            ),
                            if (driver != null && location != null)
                              const Positioned(
                                right: 14,
                                top: 14,
                                child: Chip(
                                  avatar: Icon(Icons.circle, color: Colors.blue, size: 11),
                                  label: Text('Driver'),
                                  backgroundColor: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      )
                    else
                      Container(
                        width: double.infinity,
                        height: 150,
                        color: colors.surfaceContainerLow,
                        alignment: Alignment.center,
                        child: const Padding(
                          padding: EdgeInsets.all(18),
                          child: Text(
                            'Add the Mapbox public token to enable the live tracking map. Ride status and driver details remain available below.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                        children: [
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Icon(
                                    _active ? Icons.route_rounded : Icons.check_circle_outline,
                                    color: colors.primary,
                                    size: 30,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _statusLabel(ride['status'].toString()),
                                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                                        ),
                                        Text(
                                          _active ? 'This ride is in progress. Status refreshes automatically.' : 'This ride is no longer active.',
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_active)
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(_error!, style: TextStyle(color: colors.error)),
                          ],
                          if (_environment.mapboxConfigured && _routeDistanceMeters != null) ...[
                            const SizedBox(height: 12),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    const Icon(Icons.alt_route_rounded),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        ride['status'] == 'in_progress'
                                            ? 'Route to destination'
                                            : 'Route to pickup',
                                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    Text(_formatRouteDistance(), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    const SizedBox(width: 12),
                                    Text(_formatRouteEta(), style: const TextStyle(fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (driver != null) ...[
                            const SizedBox(height: 12),
                            Text('Your driver', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: colors.primaryContainer,
                                          backgroundImage: (driver['avatar_url'] is String && (driver['avatar_url'] as String).isNotEmpty)
                                              ? NetworkImage(driver['avatar_url'] as String)
                                              : null,
                                          child: (driver['avatar_url'] is! String || (driver['avatar_url'] as String).isEmpty)
                                              ? Icon(Icons.person, color: colors.onPrimaryContainer)
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            driver['name']?.toString() ?? 'Quick-Ride driver',
                                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      [
                                        driver['vehicle_make'],
                                        driver['vehicle_model'],
                                        driver['vehicle_category'],
                                      ].where((value) => value != null && value.toString().isNotEmpty).join(' · '),
                                    ),
                                    if (driver['vehicle_registration'] != null)
                                      Text(
                                        'Vehicle number: ' + driver['vehicle_registration'].toString(),
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                    if (driver['vehicle_color'] != null)
                                      Text('Colour: ' + driver['vehicle_color'].toString()),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Icon(
                                          location == null ? Icons.location_searching : Icons.location_on,
                                          size: 18,
                                          color: location == null ? colors.onSurfaceVariant : Colors.green,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            location == null
                                                ? 'Waiting for a recent driver location update.'
                                                : _driverLocationIsStale
                                                    ? 'Driver location is delayed. Last update: ' + (DateTime.tryParse(location['recorded_at'].toString())?.toLocal().toString().substring(0, 16) ?? 'unknown')
                                                    : 'Driver location is live · updated ' + (DateTime.tryParse(location['recorded_at'].toString())?.toLocal().toString().substring(0, 16) ?? 'recently'),
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ] else if (_active) ...[
                            const SizedBox(height: 12),
                            const Card(
                              child: ListTile(
                                leading: Icon(Icons.search_rounded),
                                title: Text('Finding a driver'),
                                subtitle: Text('Driver details will appear here once a driver accepts the ride.'),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Text('Trip details', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _RouteDetail(icon: Icons.trip_origin, color: Colors.green, label: 'Pickup', address: ride['pickup_address'].toString()),
                                  const SizedBox(height: 14),
                                  _RouteDetail(icon: Icons.location_on, color: Colors.red, label: 'Destination', address: ride['destination_address'].toString()),
                                  const Divider(height: 24),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Fare'),
                                      Text(
                                        (ride['final_fare'] ?? ride['estimated_fare']) == null
                                            ? 'Pending'
                                            : '₹' + ((ride['final_fare'] ?? ride['estimated_fare']) as num).toStringAsFixed(2),
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => context.push('/support?rideId=' + Uri.encodeComponent(widget.rideId)),
                            icon: const Icon(Icons.support_agent_outlined),
                            label: const Text('Get help with this ride'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _RouteDetail extends StatelessWidget {
  const _RouteDetail({
    required this.icon,
    required this.color,
    required this.label,
    required this.address,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String address;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(address),
              ],
            ),
          ),
        ],
      );
}
