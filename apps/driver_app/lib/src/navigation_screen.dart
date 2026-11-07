import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

class DriverRideNavigationScreen extends StatefulWidget {
  const DriverRideNavigationScreen({
    super.key,
    required this.rideId,
  });

  final String rideId;

  @override
  State<DriverRideNavigationScreen> createState() =>
      _DriverRideNavigationScreenState();
}

class _DriverRideNavigationScreenState
    extends State<DriverRideNavigationScreen> {
  final MapController _mapController = MapController();
  final FlutterTts _tts = FlutterTts();

  StreamSubscription<dynamic>? _locationSubscription;
  LatLng? _currentPosition;
  LatLng? _targetPosition;
  String? _status;
  String? _destinationAddress;
  String? _error;
  List<LatLng> _routePoints = [];
  List<QuickRideRouteStep> _steps = [];
  int _currentStepIndex = 0;
  double? _distanceRemaining;
  double? _durationRemaining;
  String? _instruction;
  bool _loading = true;
  bool _mapReady = false;
  bool _routeRequestInFlight = false;
  bool _arrived = false;
  bool _finishing = false;
  bool _voiceGuidanceEnabled = true;
  String? _lastAnnouncedInstruction;
  DateTime _lastRouteFetchedAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastRouteOrigin;

  bool get _navigatingToDestination => _status == 'in_progress';

  @override
  void initState() {
    super.initState();
    unawaited(_prepareNavigation());
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    super.dispose();
  }

  LatLng _readPoint(dynamic value, String label) {
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
    return LatLng(latitude.toDouble(), longitude.toDouble());
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
          _arrived = true;
        });
        return;
      }
      if (!['accepted', 'driver_arriving', 'in_progress'].contains(status)) {
        throw StateError(
          'Navigation is only available for an active assigned ride.',
        );
      }

      final goingToDestination = status == 'in_progress';
      final target = goingToDestination
          ? _readPoint(ride['destination'], 'Destination')
          : _readPoint(ride['pickup'], 'Pickup');
      final targetAddress = goingToDestination
          ? ride['destination_address']?.toString()
          : ride['pickup_address']?.toString();

      await _initializeVoiceGuidance();
      final current = await QuickRideMaps.currentPosition();
      if (!mounted) return;
      final origin = LatLng(current.latitude, current.longitude);
      setState(() {
        _status = status;
        _targetPosition = target;
        _currentPosition = origin;
        _destinationAddress = targetAddress;
        _loading = false;
      });

      await _loadRoute(force: true);
      _locationSubscription = QuickRideMaps.watchDriverPosition().listen(
        _onLocation,
        onError: (Object error) {
          if (mounted) {
            setState(() {
              _error = 'Live GPS updates are unavailable: $error';
            });
          }
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _initializeVoiceGuidance() async {
    try {
      await _tts.setLanguage('en-IN');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
    } catch (_) {
      _voiceGuidanceEnabled = false;
    }
  }

  Future<void> _announceInstruction(String instruction) async {
    if (!_voiceGuidanceEnabled ||
        instruction == _lastAnnouncedInstruction) {
      return;
    }
    _lastAnnouncedInstruction = instruction;
    try {
      await _tts.speak(instruction);
    } catch (_) {
      // Text guidance remains available when the device has no TTS engine.
    }
  }

  void _onLocation(dynamic position) {
    if (!mounted || _targetPosition == null) return;
    final next = LatLng(
      (position.latitude as num).toDouble(),
      (position.longitude as num).toDouble(),
    );
    final previousInstruction = _instruction;
    setState(() {
      _currentPosition = next;
      _updateCurrentInstruction();
      if (_distanceMeters(next, _targetPosition!) <= 40) {
        _arrived = true;
      }
    });
    if (_instruction != null && _instruction != previousInstruction) {
      unawaited(_announceInstruction(_instruction!));
    }

    if (_mapReady) _mapController.move(next, 16);
    final last = _lastRouteOrigin;
    final moved = last == null || _distanceMeters(last, next) >= 120;
    final elapsed =
        DateTime.now().difference(_lastRouteFetchedAt) >=
            const Duration(seconds: 30);
    if (!_arrived && (moved || elapsed)) {
      unawaited(_loadRoute());
    }
  }

  Future<void> _loadRoute({bool force = false}) async {
    final origin = _currentPosition;
    final target = _targetPosition;
    if (origin == null || target == null || _routeRequestInFlight) return;
    if (!force &&
        _lastRouteOrigin != null &&
        _distanceMeters(_lastRouteOrigin!, origin) < 120 &&
        DateTime.now().difference(_lastRouteFetchedAt) <
            const Duration(seconds: 30)) {
      return;
    }

    _routeRequestInFlight = true;
    _lastRouteFetchedAt = DateTime.now();
    _lastRouteOrigin = origin;
    try {
      final route = await QuickRideMaps.drivingRoute(
        origin: origin,
        destination: target,
        includeSteps: true,
      );
      if (!mounted) return;
      setState(() {
        _routePoints = route.points;
        _steps = route.steps;
        _currentStepIndex = 0;
        _distanceRemaining = route.distanceMeters;
        _durationRemaining = route.durationSeconds;
        _instruction = _steps.isEmpty
            ? 'Follow the highlighted route'
            : _steps.first.instruction;
        _error = null;
      });
      _updateCurrentInstruction();
      if (_instruction != null) {
        unawaited(_announceInstruction(_instruction!));
      }
      if (_mapReady && _routePoints.isNotEmpty) {
        _mapController.move(origin, 16);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Route guidance is temporarily unavailable: $error';
        });
      }
    } finally {
      _routeRequestInFlight = false;
    }
  }

  void _updateCurrentInstruction() {
    final current = _currentPosition;
    if (current == null || _steps.isEmpty) return;

    var index = _currentStepIndex.clamp(0, _steps.length - 1);
    while (index < _steps.length - 1) {
      final nextStepPoint = _steps[index + 1].location;
      if (nextStepPoint != null &&
          _distanceMeters(current, nextStepPoint) <= 60) {
        index++;
      } else {
        break;
      }
    }
    _currentStepIndex = index;
    _instruction = _steps[index].instruction;
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    const radians = math.pi / 180;
    final lat1 = a.latitude * radians;
    final lat2 = b.latitude * radians;
    final dLat = (b.latitude - a.latitude) * radians;
    final dLng = (b.longitude - a.longitude) * radians;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final haversine = sinLat * sinLat +
        math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    return earthRadius *
        2 *
        math.asin(math.sqrt(haversine.clamp(0.0, 1.0)));
  }

  void _centerMap() {
    final center = _currentPosition ?? _targetPosition;
    if (center != null && _mapReady) {
      _mapController.move(center, 16);
    }
  }

  Future<void> _finishNavigation() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await _locationSubscription?.cancel();
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
    final targetLabel = _navigatingToDestination
        ? 'Navigate to destination'
        : 'Navigate to pickup';
    final current = _currentPosition;
    final target = _targetPosition;

    return Scaffold(
      appBar: AppBar(
        title: Text(_arrived ? 'Route destination reached' : targetLabel),
        actions: [
          IconButton(
            tooltip: _voiceGuidanceEnabled
                ? 'Turn off voice guidance'
                : 'Turn on voice guidance',
            onPressed: () {
              setState(() {
                _voiceGuidanceEnabled = !_voiceGuidanceEnabled;
              });
              if (_voiceGuidanceEnabled && _instruction != null) {
                unawaited(_announceInstruction(_instruction!));
              } else {
                unawaited(_tts.stop().then<void>((_) {}));
              }
            },
            icon: Icon(
              _voiceGuidanceEnabled
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
            ),
          ),
          IconButton(
            tooltip: 'Recenter navigation',
            onPressed: _centerMap,
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
              : current == null || target == null
                  ? _errorState()
                  : Column(
                      children: [
                        Expanded(
                          child: FlutterMap(
                            key: ValueKey('driver-navigation-${widget.rideId}'),
                            mapController: _mapController,
                            options: MapOptions(
                              initialCenter: current,
                              initialZoom: 16,
                              onMapReady: () {
                                _mapReady = true;
                                _centerMap();
                              },
                            ),
                            children: [
                              QuickRideMaps.openStreetMapLayer(appPackageName: 'in.quickride.driver'),
                              if (_routePoints.length >= 2)
                                PolylineLayer(
                                  polylines: [
                                    Polyline(
                                      points: _routePoints,
                                      strokeWidth: 7,
                                      color: Colors.blue,
                                    ),
                                  ],
                                ),
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: current,
                                    width: 44,
                                    height: 44,
                                    child: const Icon(
                                      Icons.navigation,
                                      color: Colors.blue,
                                      size: 36,
                                    ),
                                  ),
                                  Marker(
                                    point: target,
                                    width: 42,
                                    height: 46,
                                    child: const Icon(
                                      Icons.location_on,
                                      color: Colors.red,
                                      size: 42,
                                    ),
                                  ),
                                ],
                              ),
                              QuickRideMaps.attributionControl(),
                            ],
                          ),
                        ),
                        if (_error != null)
                          Material(
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  Expanded(child: Text(_error!)),
                                  TextButton(
                                    onPressed: () => _loadRoute(force: true),
                                    child: const Text('RETRY'),
                                  ),
                                ],
                              ),
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
                  Expanded(
                    child: _navigationMetric(
                      'Remaining',
                      _formatDistance(_distanceRemaining),
                    ),
                  ),
                  Expanded(
                    child: _navigationMetric(
                      'ETA',
                      _formatDuration(_durationRemaining),
                    ),
                  ),
                  Expanded(
                    child: _navigationMetric(
                      'Status',
                      _routeRequestInFlight ? 'Rerouting' : 'Navigating',
                    ),
                  ),
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
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      );

  Widget _arrivalMessage(String title, String subtitle) => SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.flag_circle_rounded,
                  size: 64,
                  color: Colors.green,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
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
