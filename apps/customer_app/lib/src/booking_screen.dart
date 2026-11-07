import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
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
  final MapController _mapController = MapController();
  bool _mapReady = false;
  LatLng? _pendingMapCenter;
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

  Future<String> _reverseGeocode(double longitude, double latitude) {
    return QuickRideMaps.reverseGeocode(LatLng(latitude, longitude));
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
      if (moveCamera) {
        final center = LatLng(latitude, longitude);
        if (_mapReady) {
          _mapController.move(center, 15);
        } else {
          _pendingMapCenter = center;
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<LatLng> get _quoteRoutePoints {
    final geometryValue = _quote?['route_geometry'];
    if (geometryValue is! Map) return const [];
    final geometry = Map<String, dynamic>.from(geometryValue);
    final rawCoordinates = geometry['coordinates'];
    if (rawCoordinates is! List) return const [];
    return rawCoordinates
        .whereType<List>()
        .where((pair) =>
            pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map((pair) => LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ))
        .toList(growable: false);
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
      if (mounted) {
        setState(() {
          _quote = Map<String, dynamic>.from(data['quote'] as Map);
          _booking = null;
          _pickupOtp = null;
        });
      }
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
            child: Stack(
              children: [
                FlutterMap(
                  key: const ValueKey('quick-ride-booking-map'),
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(20.5937, 78.9629),
                    initialZoom: 4.5,
                    onMapReady: () {
                      _mapReady = true;
                      final pending = _pendingMapCenter;
                      if (pending != null) {
                        _mapController.move(pending, 15);
                        _pendingMapCenter = null;
                      }
                    },
                    onTap: (_, point) => _setPoint(
                      longitude: point.longitude,
                      latitude: point.latitude,
                      pickup: _selectPickup,
                    ),
                  ),
                  children: [
                    QuickRideMaps.openStreetMapLayer(appPackageName: 'in.quickride.customer'),
                    if (_quoteRoutePoints.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _quoteRoutePoints,
                            strokeWidth: 6,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        if (_pickup != null)
                          Marker(
                            point: LatLng(_pickup!.latitude, _pickup!.longitude),
                            width: 38,
                            height: 42,
                            child: const Icon(
                              Icons.location_on,
                              color: Colors.green,
                              size: 38,
                            ),
                          ),
                        if (_destination != null)
                          Marker(
                            point: LatLng(
                              _destination!.latitude,
                              _destination!.longitude,
                            ),
                            width: 38,
                            height: 42,
                            child: const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 38,
                            ),
                          ),
                      ],
                    ),
                    QuickRideMaps.attributionControl(),
                  ],
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
                    onChanged: _busy ? null : (value) {
                      setState(() {
                        _categoryId = value;
                        _quote = null;
                      });
                      _clearQuoteRoute();
                    },
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
