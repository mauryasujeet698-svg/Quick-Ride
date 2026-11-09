import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;


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
  const CustomerBookingScreen({super.key, this.initialPickup, this.initialDestination});
  final RidePoint? initialPickup;
  final RidePoint? initialDestination;
  @override
  State<CustomerBookingScreen> createState() => _CustomerBookingScreenState();
}

class _CustomerBookingScreenState extends State<CustomerBookingScreen> {
  final _pin = TextEditingController();
  mbx.MapboxMap? _mapboxMap;
  RidePoint? _pickup;
  RidePoint? _destination;
  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  String _rideMode = 'private';
  int _passengerCount = 1;
  bool _selectPickup = true;
  bool _busy = false;
  bool _loadingCategories = true;
  String? _error;
  Map<String, dynamic>? _quote;
  Map<String, dynamic>? _booking;
  Map<String, dynamic>? _sharedAuto;
  String? _pickupOtp;

  @override
  void initState() {
    super.initState();
    _pickup = widget.initialPickup;
    _destination = widget.initialDestination;
    _selectPickup = _pickup == null;
    _loadCategories();
    if (_pickup == null) _tryCurrentLocation();
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  String get _selectedCategoryCode {
    for (final category in _categories) {
      if ((category['id'] as num).toInt() == _categoryId) {
        return category['code'].toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      }
    }
    return '';
  }

  bool get _canShareAuto =>
      _selectedCategoryCode == 'auto' || _selectedCategoryCode == 'autorickshaw';

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
        final map = _mapboxMap;
        if (map != null) {
          unawaited(map.flyTo(
            mbx.CameraOptions(
              center: mbx.Point(coordinates: mbx.Position(longitude, latitude)),
              zoom: 15,
            ),
            mbx.MapAnimationOptions(duration: 650),
          ));
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
        'rideMode': _rideMode,
        'passengerCount': _rideMode == 'shared_auto' ? _passengerCount : 1,
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
          _sharedAuto = null;
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
        _sharedAuto = data['shared_auto'] is Map
            ? Map<String, dynamic>.from(data['shared_auto'] as Map)
            : null;
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
                QuickRideMapView(
                  key: const ValueKey('quick-ride-booking-mapbox-map'),
                  initialCenter: _pickup == null
                      ? const LatLng(20.5937, 78.9629)
                      : LatLng(_pickup!.latitude, _pickup!.longitude),
                  initialZoom: _pickup == null ? 4.5 : 15,
                  currentPosition: _pickup == null
                      ? null
                      : LatLng(_pickup!.latitude, _pickup!.longitude),
                  pickup: _pickup == null
                      ? null
                      : LatLng(_pickup!.latitude, _pickup!.longitude),
                  destination: _destination == null
                      ? null
                      : LatLng(_destination!.latitude, _destination!.longitude),
                  routePoints: _quoteRoutePoints,
                  onMapCreated: (map) => _mapboxMap = map,
                  onTap: (point) => _setPoint(
                    longitude: point.longitude,
                    latitude: point.latitude,
                    pickup: _selectPickup,
                  ),
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
                        _rideMode = 'private';
                        _passengerCount = 1;
                        _quote = null;
                        _sharedAuto = null;
                      });
                    },
                  ),
                if (_canShareAuto) ...[
                  const SizedBox(height: 10),
                  Text('Auto booking type', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'private', label: Text('Private Auto')),
                      ButtonSegment(value: 'shared_auto', label: Text('Shared Auto')),
                    ],
                    selected: {_rideMode},
                    onSelectionChanged: _busy ? null : (selection) {
                      setState(() {
                        _rideMode = selection.first;
                        _quote = null;
                        _sharedAuto = null;
                        if (_rideMode == 'private') _passengerCount = 1;
                      });
                    },
                  ),
                  if (_rideMode == 'shared_auto') ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: _passengerCount,
                      decoration: const InputDecoration(
                        labelText: 'Number of passengers',
                        helperText: 'Shared Auto supports up to 3 passengers in total.',
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 passenger')),
                        DropdownMenuItem(value: 2, child: Text('2 passengers')),
                        DropdownMenuItem(value: 3, child: Text('3 passengers')),
                      ],
                      onChanged: _busy ? null : (value) {
                        if (value == null) return;
                        setState(() {
                          _passengerCount = value;
                          _quote = null;
                        });
                      },
                    ),
                  ],
                ],
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
                  onPressed: _busy ? null : _getQuote,
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
                          Text(
                            _rideMode == 'shared_auto'
                                ? 'Shared Auto · $_passengerCount passenger(s)'
                                : 'Estimated fare',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (_rideMode == 'shared_auto')
                            const Text('Your price is per booking. Other passengers have separate bookings and fares.'),
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
                          Text(
                            _sharedAuto == null ? 'Ride requested' : 'Shared Auto requested',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text('Ride ID: ' + _booking!['id'].toString()),
                          if (_sharedAuto != null) ...[
                            Text('Shared Auto seats reserved: ' +
                                (_sharedAuto!['reserved_seats'] ?? _passengerCount).toString() +
                                ' of ' + (_sharedAuto!['seat_capacity'] ?? 3).toString()),
                            if (_sharedAuto!['joined_existing_trip'] == true)
                              const Text('You joined an existing compatible Auto trip.'),
                            if (_sharedAuto!['status'] != null)
                              Text('Shared trip status: ' + _sharedAuto!['status'].toString().replaceAll('_', ' ')),
                          ],
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
