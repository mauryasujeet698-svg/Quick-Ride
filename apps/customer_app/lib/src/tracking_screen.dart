import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

class CustomerRideTrackingScreen extends StatefulWidget {
  const CustomerRideTrackingScreen({super.key, required this.rideId});

  final String rideId;

  @override
  State<CustomerRideTrackingScreen> createState() => _CustomerRideTrackingScreenState();
}

class _CustomerRideTrackingScreenState extends State<CustomerRideTrackingScreen> {
  QuickRideMapController? _mapController;
  List<LatLng> _routePoints = [];
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
  LatLng? _lastRouteOrigin;
  double? _routeDistanceMeters;
  double? _routeDurationSeconds;
  String? _error;
  bool _sharingRide = false;
  bool _shareLinkActive = false;

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

  LatLng? _position(dynamic value) {
    final point = _asPoint(value);
    if (point == null) return null;
    return LatLng(
      point['latitude'] as double,
      point['longitude'] as double,
    );
  }

  Future<void> _syncMap() async {
    final tracking = _tracking;
    if (tracking == null) return;

    final ride = Map<String, dynamic>.from(tracking['ride'] as Map);
    final driver = tracking['driver'] is Map
        ? Map<String, dynamic>.from(tracking['driver'] as Map)
        : null;
    final pickup = _position(ride['pickup']);
    final destination = _position(ride['destination']);
    final driverLocation = driver == null
        ? null
        : _position(driver['location']);

    unawaited(_refreshRouteIfNeeded(
      ride,
      pickup,
      destination,
      driverLocation,
    ));

    final map = _mapController;
    if (!_cameraInitialized && map != null) {
      final center = driverLocation ?? pickup ?? destination;
      if (center != null) {
        map.moveTo(center, zoom: 14);
        _cameraInitialized = true;
      }
    }
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final lat1 = a.latitude * 0.017453292519943295;
    final lat2 = b.latitude * 0.017453292519943295;
    final dLat = (b.latitude - a.latitude) * 0.017453292519943295;
    final dLng = (b.longitude - a.longitude) * 0.017453292519943295;
    final sinLat = (dLat / 2).abs();
    final sinLng = (dLng / 2).abs();
    final haversine = sinLat * sinLat +
        (math.cos(lat1) * math.cos(lat2) * sinLng * sinLng);
    final clamped = haversine.clamp(0.0, 1.0);
    return earthRadius * 2 * math.asin(math.sqrt(clamped));
  }

  Future<void> _refreshRouteIfNeeded(
    Map<String, dynamic> ride,
    LatLng? pickup,
    LatLng? destination,
    LatLng? driverLocation,
  ) async {
    if (_routeRequestInFlight || pickup == null || destination == null) {
      return;
    }
    final status = ride['status']?.toString() ?? '';
    if (driverLocation == null ||
        !const {'accepted', 'driver_arriving', 'arrived', 'in_progress'}
            .contains(status)) {
      if (_routePoints.isNotEmpty ||
          _routeDistanceMeters != null ||
          _routeDurationSeconds != null) {
        if (mounted) {
          setState(() {
            _routePoints = [];
            _routeDistanceMeters = null;
            _routeDurationSeconds = null;
          });
        }
      }
      return;
    }

    final origin = driverLocation;
    final target = status == 'in_progress' ? destination : pickup;
    final now = DateTime.now();
    final statusChanged = status != _lastRouteStatus;
    final originMoved = _lastRouteOrigin == null ||
        _distanceMeters(_lastRouteOrigin!, origin) >= 150;
    final intervalElapsed =
        now.difference(_lastRouteFetchedAt) >= const Duration(seconds: 30);
    if (!statusChanged && !originMoved && !intervalElapsed) return;

    _routeRequestInFlight = true;
    _lastRouteFetchedAt = now;
    _lastRouteStatus = status;
    _lastRouteOrigin = origin;

    try {
      final route = await QuickRideMaps.drivingRoute(
        origin: origin,
        destination: target,
      );
      if (!mounted) return;
      setState(() {
        _routePoints = route.points;
        _routeDistanceMeters = route.distanceMeters;
        _routeDurationSeconds = route.durationSeconds;
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

  Future<void> _shareRide(BuildContext shareContext) async {
    if (_sharingRide || !_active) return;
    setState(() { _sharingRide = true; });
    try {
      final response = await QuickRideBackend.invoke(
        'ride-booking',
        body: {
          'action': 'create_share_link',
          'rideId': widget.rideId,
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final shareUrl = data['share_url']?.toString();
      final expiresAt = DateTime.tryParse(data['expires_at']?.toString() ?? '');
      if (shareUrl == null || shareUrl.isEmpty) {
        throw StateError('The trip-share link was not returned by the server.');
      }
      if (mounted) setState(() => _shareLinkActive = true);

      final box = shareContext.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      final expiryText = expiresAt == null
          ? '12 hours'
          : 'until ' + expiresAt.toLocal().toString().substring(0, 16);
      final message = [
        'I am sharing my Quick-Ride trip with you.',
        'Track the ride status, route and recent driver location here:',
        shareUrl,
        'This private link expires $expiryText. Anyone with the link can view these ride details.',
      ].join('\n\n');
      await SharePlus.instance.share(
        ShareParams(
          title: 'Quick-Ride trip',
          text: message,
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share this ride: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharingRide = false);
    }
  }

  Future<void> _stopRideSharing() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop sharing this ride?'),
        content: const Text(
          'The current private share link will stop working immediately. '
          'Anyone who already received it will no longer be able to open it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep sharing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Stop sharing'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _sharingRide = true);
    try {
      await QuickRideBackend.invoke(
        'ride-booking',
        body: {
          'action': 'revoke_share_links',
          'rideId': widget.rideId,
        },
      );
      if (mounted) {
        setState(() => _shareLinkActive = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip sharing has been stopped.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop trip sharing: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharingRide = false);
    }
  }

  Future<void> _openEmergencyDialer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Emergency assistance'),
        content: const Text(
          'For an immediate emergency in India, call 112. '
          'Quick-Ride will try to record an SOS event for this active ride, '
          'then open your phone dialer. You must confirm the call in the dialer. '
          'Quick-Ride is not an emergency dispatch service.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open 112 dialer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    var recorded = false;
    try {
      await QuickRideBackend.invoke(
        'ride-booking',
        body: {
          'action': 'safety_event',
          'rideId': widget.rideId,
        },
      ).timeout(const Duration(seconds: 3));
      recorded = true;
    } catch (_) {
      // Do not prevent the customer from reaching the public emergency number.
    }

    var dialerOpened = false;
    try {
      dialerOpened = await launchUrl(Uri(scheme: 'tel', path: '112'));
    } catch (_) {
      dialerOpened = false;
    }
    if (!mounted) return;

    final message = !dialerOpened
        ? 'Could not open the phone dialer. Please dial 112 manually.'
        : recorded
            ? 'SOS event recorded. Confirm the emergency call in your phone dialer.'
            : 'Emergency dialer opened. SOS could not be recorded; confirm the call in your phone dialer.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _centerOnDriver() async {
    final point = _position(_driverLocation) ??
        _position(_ride?['pickup']) ??
        _position(_ride?['destination']);
    if (point == null) return;
    final map = _mapController;
    if (map != null) {
      map.moveTo(point, zoom: 15);
    }
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
                    SizedBox(
                      height: 290,
                      child: Stack(
                        children: [
                          QuickRideMapView(
                            key: ValueKey('ride-tracking-${widget.rideId}'),
                            initialCenter: _position(ride['pickup']) ??
                                const LatLng(20.5937, 78.9629),
                            initialZoom: _position(ride['pickup']) == null ? 4.5 : 14,
                            showUserLocation: false,
                            currentPosition: _position(location),
                            pickup: _position(ride['pickup']),
                            destination: _position(ride['destination']),
                            routePoints: _routePoints,
                            followCurrentPosition: _active,
                            fitRouteBottomInset: 70,
                            onMapCreated: (map) {
                              _mapController = map;
                              unawaited(_syncMap());
                            },
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
                          if (_routeDistanceMeters != null) ...[
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
                          if (_active) ...[
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _sharingRide ? null : () => _shareRide(context),
                              icon: _sharingRide
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.share_outlined),
                              label: Text(_sharingRide ? 'Preparing share link…' : 'Share live trip'),
                            ),
                            if (_shareLinkActive)
                              TextButton.icon(
                                onPressed: _sharingRide ? null : _stopRideSharing,
                                icon: const Icon(Icons.link_off),
                                label: const Text('Stop sharing link'),
                              ),
                            const Padding(
                              padding: EdgeInsets.only(bottom: 6),
                              child: Text(
                                'The private link expires after 12 hours. Creating a new link revokes the previous one.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Emergency assistance',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 5),
                                  const Text('For immediate danger in India, call the official emergency number 112.'),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: _active ? _openEmergencyDialer : null,
                                      style: FilledButton.styleFrom(
                                        backgroundColor: colors.error,
                                        foregroundColor: colors.onError,
                                      ),
                                      icon: const Icon(Icons.call_rounded),
                                      label: const Text('Emergency · Call 112'),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Quick-Ride can record the SOS event when online, but it does not contact emergency responders on your behalf.',
                                    style: Theme.of(context).textTheme.bodySmall,
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
