import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

class RidePoint {
  const RidePoint({
    required this.longitude,
    required this.latitude,
    required this.address,
  });
  final double longitude;
  final double latitude;
  final String address;

  Map<String, dynamic> toJson() => {
        'longitude': longitude,
        'latitude': latitude,
        'address': address,
      };
}

class CustomerBookingScreen extends StatefulWidget {
  const CustomerBookingScreen({super.key});
  @override
  State<CustomerBookingScreen> createState() => _CustomerBookingScreenState();
}

class _CustomerBookingScreenState extends State<CustomerBookingScreen> {
  final _pin = TextEditingController();
  final _environment = QuickRideEnvironment.fromBuildDefines();
  MapboxMap? _map;
  CircleAnnotationManager? _markerManager;
  CircleAnnotation? _pickupMarker;
  CircleAnnotation? _destinationMarker;
  RidePoint? _pickup;
  RidePoint? _destination;
  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  bool _selectPickup = true;
  bool _busy = false;
  bool _loadingCategories = true;
  String? _error;
  Map<String, dynamic>? _quote;
  Map<String, dynamic>? _booking;
  String? _pickupOtp;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _tryCurrentLocation();
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final rows = await QuickRideBackend.client
          .from('vehicle_categories')
          .select('id,code,name')
          .eq('is_active', true)
          .order('id');
      if (!mounted) return;
      setState(() {
        _categories = rows;
        _categoryId = rows.isEmpty ? null : (rows.first['id'] as num).toInt();
        _loadingCategories = false;
      });
    } catch (error) {
      if (mounted) setState(() {
        _loadingCategories = false;
        _error = 'Vehicle options could not be loaded: ' + error.toString();
      });
    }
  }

  Future<void> _tryCurrentLocation() async {
    try {
      final position = await QuickRideMaps.currentPosition();
      if (!mounted) return;
      await _setPoint(
        longitude: position.longitude,
        latitude: position.latitude,
        pickup: true,
        moveCamera: true,
      );
    } catch (_) {
      // Location is optional; map selection remains available.
    }
  }

  Future<String> _reverseGeocode(double longitude, double latitude) async {
    final token = _environment.mapboxPublicToken;
    if (token.isEmpty) return 'Selected map location';
    final uri = Uri.https('api.mapbox.com', '/search/geocode/v6/reverse', {
      'longitude': longitude.toString(),
      'latitude': latitude.toString(),
      'access_token': token,
      'country': 'IN',
      'language': 'en',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('Mapbox could not resolve this location (' +
          response.statusCode.toString() + ').');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final features = payload['features'] as List<dynamic>? ?? [];
    if (features.isEmpty) return 'Selected map location';
    final properties = features.first['properties'] as Map<String, dynamic>? ?? {};
    return (properties['full_address'] ??
            properties['name'] ??
            'Selected map location')
        .toString();
  }

  Future<void> _setPoint({
    required double longitude,
    required double latitude,
    required bool pickup,
    bool moveCamera = false,
  }) async {
    if (longitude < 68 || longitude > 98 || latitude < 6 || latitude > 38) {
      setState(() => _error = 'Choose a location inside India.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final address = await _reverseGeocode(longitude, latitude);
      if (!mounted) return;
      final point = RidePoint(
        longitude: longitude,
        latitude: latitude,
        address: address,
      );
      setState(() {
        if (pickup) {
          _pickup = point;
        } else {
          _destination = point;
        }
        _quote = null;
      });
      await _syncPointMarkers();
      if (moveCamera && _map != null) {
        await _map!.setCamera(CameraOptions(
          center: Point(coordinates: Position(longitude, latitude)),
          zoom: 15,
        ));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    map.addInteraction(
      TapInteraction.onMap((context) {
        final coordinates = context.point.coordinates;
        _setPoint(
          longitude: coordinates.lng.toDouble(),
          latitude: coordinates.lat.toDouble(),
          pickup: _selectPickup,
        );
      }),
      interactionID: 'quick-ride-pickup-destination',
    );
    _markerManager = await map.annotations.createCircleAnnotationManager();
    await _syncPointMarkers();
  }

  Future<void> _syncPointMarkers() async {
    final manager = _markerManager;
    if (manager == null) return;

    if (_pickup != null) {
      final options = CircleAnnotationOptions(
        geometry: Point(
          coordinates: Position(_pickup!.longitude, _pickup!.latitude),
        ),
        circleColor: Colors.green.toARGB32(),
        circleRadius: 10,
        circleStrokeColor: Colors.white.toARGB32(),
        circleStrokeWidth: 3,
      );
      if (_pickupMarker == null) {
        _pickupMarker = await manager.create(options);
      } else {
        _pickupMarker!.geometry = options.geometry;
        await manager.update(_pickupMarker!);
      }
    }

    if (_destination != null) {
      final options = CircleAnnotationOptions(
        geometry: Point(
          coordinates: Position(_destination!.longitude, _destination!.latitude),
        ),
        circleColor: Colors.red.toARGB32(),
        circleRadius: 10,
        circleStrokeColor: Colors.white.toARGB32(),
        circleStrokeWidth: 3,
      );
      if (_destinationMarker == null) {
        _destinationMarker = await manager.create(options);
      } else {
        _destinationMarker!.geometry = options.geometry;
        await manager.update(_destinationMarker!);
      }
    }
  }

  Map<String, dynamic> _request(String action) => {
        'action': action,
        'pincode': _pin.text.trim(),
        'vehicleCategoryId': _categoryId,
        'pickup': _pickup!.toJson(),
        'destination': _destination!.toJson(),
      };

  Future<void> _getQuote() async {
    if (QuickRideAuth.currentUser == null) {
      setState(() => _error = 'Sign in with Google to request a fare estimate.');
      await QuickRideAuth.signInWithGoogle(
        redirectTo: 'in.quickride.customer://login-callback',
      );
      return;
    }
    if (_pickup == null || _destination == null) {
      setState(() => _error = 'Select both pickup and destination on the map.');
      return;
    }
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(_pin.text.trim())) {
      setState(() => _error = 'Enter the pickup service pincode.');
      return;
    }
    if (_categoryId == null) {
      setState(() => _error = 'No active vehicle category is configured.');
      return;
    }
    await _run(() async {
      final result = await QuickRideBackend.invoke(
        'ride-booking',
        body: _request('quote'),
      );
      final data = Map<String, dynamic>.from(result.data as Map);
      if (mounted) setState(() {
        _quote = Map<String, dynamic>.from(data['quote'] as Map);
        _booking = null;
        _pickupOtp = null;
      });
    });
  }

  Future<void> _bookRide() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      setState(() => _error = 'Sign in before confirming your ride.');
      await QuickRideAuth.signInWithGoogle(
        redirectTo: 'in.quickride.customer://login-callback',
      );
      return;
    }
    if (_quote == null) return;
    await _run(() async {
      final key = DateTime.now().microsecondsSinceEpoch.toString() +
          '-' + Random.secure().nextInt(1 << 32).toString();
      final response = await QuickRideBackend.invoke(
        'ride-booking',
        body: {..._request('book'), 'idempotencyKey': key},
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (mounted) setState(() {
        _booking = Map<String, dynamic>.from(data['ride'] as Map);
        _pickupOtp = data['pickup_otp']?.toString();
      });
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokenReady = _environment.mapboxPublicToken.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book a ride'),
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 6,
            child: tokenReady
                ? Stack(
                    children: [
                      MapWidget(
                        key: const ValueKey('quick-ride-booking-map'),
                        viewport: CameraViewportState(
                          center: Point(coordinates: Position(78.9629, 20.5937)),
                          zoom: 4.5,
                        ),
                        onMapCreated: _onMapCreated,
                      ),
                      const Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: IgnorePointer(
                          child: Card(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Tap the map to set the selected location'),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'current-location',
                          onPressed: _tryCurrentLocation,
                          child: const Icon(Icons.my_location),
                        ),
                      ),
                    ],
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Mapbox public token is not configured. Add MAPBOX_PUBLIC_TOKEN as a build-time define to enable map selection.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              children: [
                TextField(
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'Pickup pincode',
                    counterText: '',
                    prefixIcon: Icon(Icons.pin_drop_outlined),
                  ),
                ),
                if (_loadingCategories)
                  const LinearProgressIndicator()
                else
                  DropdownButtonFormField<int>(
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: 'Vehicle type'),
                    items: _categories.map((category) {
                      final id = (category['id'] as num).toInt();
                      return DropdownMenuItem(
                        value: id,
                        child: Text(category['name'].toString() +
                            ' (' + category['code'].toString() + ')'),
                      );
                    }).toList(),
                    onChanged: _busy ? null : (value) => setState(() {
                      _categoryId = value;
                      _quote = null;
                    }),
                  ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Set pickup'), icon: Icon(Icons.trip_origin)),
                    ButtonSegment(value: false, label: Text('Set destination'), icon: Icon(Icons.flag_outlined)),
                  ],
                  selected: {_selectPickup},
                  onSelectionChanged: (selection) => setState(() => _selectPickup = selection.first),
                ),
                const SizedBox(height: 10),
                _pointTile('Pickup', _pickup),
                _pointTile('Destination', _destination),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _busy || !tokenReady ? null : _getQuote,
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text('Get fare estimate'),
                ),
                if (_quote != null) ...[
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Estimated fare', style: Theme.of(context).textTheme.titleMedium),
                          Text(
                            '₹' + (_quote!['estimated_fare'] as num).toStringAsFixed(2),
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          Text(
                            ((_quote!['distance_m'] as num) / 1000).toStringAsFixed(1) +
                                ' km · ' + (((_quote!['duration_s'] as num) / 60).ceil()).toString() + ' min',
                          ),
                          const SizedBox(height: 10),
                          FilledButton(
                            onPressed: _busy ? null : _bookRide,
                            child: const Text('Confirm booking'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_booking != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Ride requested', style: Theme.of(context).textTheme.titleLarge),
                          Text('Ride ID: ' + _booking!['id'].toString()),
                          Text('Status: ' + _booking!['status'].toString()),
                          if (_pickupOtp != null) ...[
                            const SizedBox(height: 8),
                            Text('Pickup OTP: ' + _pickupOtp!,
                                style: Theme.of(context).textTheme.headlineSmall),
                            const Text('Share this code with your driver when you are ready to start the trip.'),
                          ],
                        ],
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => context.push(
                      '/ride/' + Uri.encodeComponent(_booking!['id'].toString()),
                    ),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Track this ride'),
                  ),
                  _RideStatusStream(rideId: _booking!['id'].toString()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pointTile(String label, RidePoint? point) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(label == 'Pickup' ? Icons.trip_origin : Icons.flag_outlined),
        title: Text(label),
        subtitle: Text(point?.address ?? 'Tap the map to select'),
        trailing: point == null ? const Icon(Icons.location_searching) : const Icon(Icons.check_circle),
      );
}

class _RideStatusStream extends StatelessWidget {
  const _RideStatusStream({required this.rideId});
  final String rideId;

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (user == null || !QuickRideBackend.isInitialized) return const SizedBox.shrink();
    final stream = QuickRideBackend.client
        .from('rides')
        .stream(primaryKey: ['id'])
        .eq('customer_id', user.id);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final matching = snapshot.data!.where((row) => row['id'].toString() == rideId);
        if (matching.isEmpty) return const SizedBox.shrink();
        final ride = matching.first;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Live ride status'),
            subtitle: Text(ride['status'].toString().replaceAll('_', ' ')),
          ),
        );
      },
    );
  }
}
