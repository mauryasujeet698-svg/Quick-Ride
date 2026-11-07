import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';

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
  Timer? _refreshTimer;
  Map<String, dynamic>? _tracking;
  bool _loading = true;
  bool _refreshing = false;
  bool _cameraInitialized = false;
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
    unawaited(_refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
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
    super.dispose();
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
      await _syncMap();
    } catch (error) {
      if (mounted) setState(() => _error = 'The tracking map could not be initialized: ' + error.toString());
    }
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

    final options = <CircleAnnotationOptions>[];
    if (pickup != null) {
      options.add(CircleAnnotationOptions(
        geometry: Point(coordinates: pickup),
        circleColor: Colors.green.value,
        circleRadius: 9,
        circleStrokeColor: Colors.white.value,
        circleStrokeWidth: 2,
      ));
    }
    if (destination != null) {
      options.add(CircleAnnotationOptions(
        geometry: Point(coordinates: destination),
        circleColor: Colors.red.value,
        circleRadius: 9,
        circleStrokeColor: Colors.white.value,
        circleStrokeWidth: 2,
      ));
    }
    if (driverLocation != null) {
      options.add(CircleAnnotationOptions(
        geometry: Point(coordinates: driverLocation),
        circleColor: Colors.blue.value,
        circleRadius: 11,
        circleStrokeColor: Colors.white.value,
        circleStrokeWidth: 3,
      ));
    }

    await manager.deleteAll();
    if (options.isNotEmpty) await manager.createMulti(options);

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
                                                : 'Driver location received ' + (DateTime.tryParse(location['recorded_at'].toString())?.toLocal().toString().substring(0, 16) ?? 'recently') + '.',
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
