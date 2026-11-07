import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mapbox/flutter_mapbox.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

class DriverRideNavigationScreen extends StatefulWidget {
  const DriverRideNavigationScreen({super.key, required this.rideId});

  final String rideId;

  @override
  State<DriverRideNavigationScreen> createState() =>
      _DriverRideNavigationScreenState();
}

class _DriverRideNavigationScreenState
    extends State<DriverRideNavigationScreen> {
  MapBoxNavigationViewController? _controller;
  MapBoxOptions? _options;
  String? _status;
  String? _destinationAddress;
  String? _error;
  String? _instruction;
  double? _distanceRemaining;
  double? _durationRemaining;
  bool _loading = true;
  bool _routeReady = false;
  bool _navigationStarted = false;
  bool _arrived = false;
  bool _finishing = false;
  List<WayPoint> _pendingWaypoints = const [];

  bool get _navigatingToDestination => _status == 'in_progress';

  @override
  void initState() {
    super.initState();
    unawaited(_prepareNavigation());
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null && _navigationStarted) {
      unawaited(controller.finishNavigation().then<void>((_) {}));
    }
    super.dispose();
  }

  Map<String, dynamic> _readPoint(dynamic value, String label) {
    if (value is! Map) {
      throw StateError('$label coordinates are unavailable for this ride.');
    }
    final point = Map<String, dynamic>.from(value);
    final latitude = point['latitude'];
    final longitude = point['longitude'];
    if (latitude is! num ||
        longitude is! num ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < 6 ||
        latitude > 38 ||
        longitude < 68 ||
        longitude > 98) {
      throw StateError('$label coordinates are invalid.');
    }
    return {
      'latitude': latitude.toDouble(),
      'longitude': longitude.toDouble(),
    };
  }

  Future<void> _prepareNavigation() async {
    try {
      final response = await QuickRideBackend.client.rpc(
        'get_driver_ride_navigation',
        params: {'p_ride_id': widget.rideId},
      );
      final payload = Map<String, dynamic>.from(response as Map);
      final ride = Map<String, dynamic>.from(payload['ride'] as Map);
      final status = ride['status']?.toString() ?? '';

      if (status == 'arrived') {
        if (!mounted) return;
        setState(() {
          _status = status;
          _destinationAddress = ride['pickup_address']?.toString();
          _loading = false;
        });
        return;
      }
      if (!['accepted', 'driver_arriving', 'in_progress'].contains(status)) {
        throw StateError('Navigation is only available for an active assigned ride.');
      }

      final goingToDestination = status == 'in_progress';
      final target = goingToDestination
          ? _readPoint(ride['destination'], 'Destination')
          : _readPoint(ride['pickup'], 'Pickup');
      final targetAddress = goingToDestination
          ? ride['destination_address']?.toString()
          : ride['pickup_address']?.toString();

      final current = await QuickRideMaps.currentPosition();
      if (!mounted) return;

      final options = MapBoxOptions(
        initialLatitude: current.latitude,
        initialLongitude: current.longitude,
        zoom: 15,
        tilt: 45,
        bearing: current.heading.isFinite ? current.heading : 0,
        mode: MapBoxNavigationMode.drivingWithTraffic,
        units: VoiceUnits.metric,
        alternatives: true,
        enableRefresh: true,
        voiceInstructionsEnabled: true,
        bannerInstructionsEnabled: true,
        allowsUTurnAtWayPoints: true,
        simulateRoute: false,
        longPressDestinationEnabled: false,
        mapStyleUrlDay: 'mapbox://styles/mapbox/navigation-day-v1',
        mapStyleUrlNight: 'mapbox://styles/mapbox/navigation-night-v1',
        language: 'en',
      );

      setState(() {
        _status = status;
        _destinationAddress = targetAddress;
        _options = options;
        _loading = false;
      });
      _pendingWaypoints = [
        WayPoint(
          id: 'driver-origin',
          name: 'Your current location',
          latitude: current.latitude,
          longitude: current.longitude,
        ),
        WayPoint(
          id: 'ride-target',
          name: goingToDestination ? 'Customer destination' : 'Customer pickup',
          latitude: target['latitude'] as double,
          longitude: target['longitude'] as double,
        ),
      ];
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _onNavigationViewCreated(
    MapBoxNavigationViewController controller,
  ) async {
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      final built = await controller.buildRoute(
        wayPoints: _pendingWaypoints,
        options: _options,
      );
      if (!mounted) return;
      if (!built) {
        setState(() => _error = 'Mapbox could not build a route to this location.');
        return;
      }
      setState(() => _routeReady = true);
      final started = await controller.startNavigation();
      if (!mounted) return;
      setState(() => _navigationStarted = started == true);
    } catch (error) {
      if (mounted) setState(() => _error = 'Navigation could not start: $error');
    }
  }

  void _onRouteEvent(RouteEvent event) {
    if (!mounted) return;
    if (event.eventType == MapBoxEvent.progress_change &&
        event.data is RouteProgressEvent) {
      final progress = event.data as RouteProgressEvent;
      setState(() {
        _instruction = progress.currentStepInstruction;
        _distanceRemaining = progress.currentLegDistanceRemaining ?? progress.distance;
        _durationRemaining = progress.duration;
        if (progress.arrived == true) _arrived = true;
      });
    } else if (event.eventType == MapBoxEvent.on_arrival) {
      setState(() => _arrived = true);
    } else if (event.eventType == MapBoxEvent.route_build_failed ||
        event.eventType == MapBoxEvent.route_build_no_routes_found ||
        event.eventType == MapBoxEvent.failed_to_reroute) {
      setState(() => _error = 'Mapbox could not calculate or refresh this route. Check GPS and network access, then retry.');
    }
  }

  Future<void> _finishNavigation() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await _controller?.finishNavigation();
    } catch (_) {
      // The user can still return to the ride controls.
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _formatDistance(double? meters) {
    if (meters == null || !meters.isFinite) return '—';
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  String _formatDuration(double? seconds) {
    if (seconds == null || !seconds.isFinite || seconds < 0) return '—';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return '${hours}h ${remainder}m';
  }

  @override
  Widget build(BuildContext context) {
    final targetLabel =
        _navigatingToDestination ? 'Navigate to destination' : 'Navigate to pickup';

    return Scaffold(
      appBar: AppBar(
        title: Text(_arrived ? 'Route destination reached' : targetLabel),
        actions: [
          IconButton(
            tooltip: 'Recenter navigation',
            onPressed: _controller == null ? null : () => _controller!.reCenterCamera(),
            icon: const Icon(Icons.my_location),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _status == 'arrived'
              ? _arrivalMessage(
                  'You are at the pickup point.',
                  'Return to the ride controls to verify the passenger OTP and start the trip.',
                )
              : _error != null && _options == null
                  ? _errorState()
                  : _options == null
                      ? _errorState()
                      : Column(
                          children: [
                            Expanded(
                              child: MapBoxNavigationView(
                                key: ValueKey('driver-navigation-${widget.rideId}'),
                                options: _options,
                                onCreated: _onNavigationViewCreated,
                                onRouteEvent: _onRouteEvent,
                              ),
                            ),
                            if (_error != null)
                              Material(
                                color: Theme.of(context).colorScheme.errorContainer,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(_error!),
                                ),
                              ),
                            if (_arrived)
                              _arrivalMessage(
                                _navigatingToDestination
                                    ? 'You have reached the destination.'
                                    : 'You have reached the pickup point.',
                                _navigatingToDestination
                                    ? 'Return to the ride controls and complete the trip after confirming the drop-off.'
                                    : 'Return to the ride controls to mark arrival and verify the passenger OTP.',
                              )
                            else
                              _navigationStatusCard(),
                          ],
                        ),
    );
  }

  Widget _navigationStatusCard() => SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _instruction ?? 'Calculating route…',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (_destinationAddress != null) ...[
                const SizedBox(height: 4),
                Text(
                  _destinationAddress!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _navigationMetric('Remaining', _formatDistance(_distanceRemaining))),
                  Expanded(child: _navigationMetric('ETA', _formatDuration(_durationRemaining))),
                  Expanded(child: _navigationMetric('Status', _navigationStarted ? 'Navigating' : _routeReady ? 'Starting' : 'Routing')),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _finishing ? null : _finishNavigation,
                icon: const Icon(Icons.close),
                label: const Text('Return to ride controls'),
              ),
            ],
          ),
        ),
      );

  Widget _navigationMetric(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ],
      );

  Widget _arrivalMessage(String title, String subtitle) => SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.flag_circle_rounded, size: 64, color: Colors.green),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(subtitle, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _finishNavigation,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Return to ride controls'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.navigation_outlined, size: 56),
              const SizedBox(height: 12),
              Text(
                _error ?? 'Navigation is unavailable.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to ride'),
              ),
            ],
          ),
        ),
      );
}
