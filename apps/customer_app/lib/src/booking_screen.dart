import 'dart:async';
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
    this.pincode,
  });
  final double longitude;
  final double latitude;
  final String address;
  final String? pincode;

  Map<String, dynamic> toJson() => {
        'longitude': longitude,
        'latitude': latitude,
        'address': address,
        'pincode': pincode,
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
  QuickRideMapController? _mapController;
  RidePoint? _pickup;
  RidePoint? _destination;
  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  String _rideMode = 'private';
  int _passengerCount = 1;
  int _sharedAutoCapacity = 3;
  bool _selectPickup = true;
  bool _busy = false;
  bool _loadingCategories = true;
  String? _error;
  Map<String, dynamic>? _quote;
  List<Map<String, dynamic>> _serviceQuotes = [];
  Map<String, dynamic>? _booking;
  Map<String, dynamic>? _sharedAuto;
  String? _pickupOtp;

  @override
  void initState() {
    super.initState();
    _pickup = widget.initialPickup;
    _destination = widget.initialDestination;
    _pin.text = widget.initialPickup?.pincode ?? '';
    _selectPickup = _pickup == null;
    _loadCategories();
    if (_pickup == null) _tryCurrentLocation();
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
      final pincode = RegExp(r'(?<![0-9])[1-9][0-9]{5}(?![0-9])')
          .firstMatch(address)
          ?.group(0);
      final point = RidePoint(
        longitude: longitude,
        latitude: latitude,
        address: address,
        pincode: pincode,
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
        _mapController?.moveTo(
          LatLng(latitude, longitude),
          zoom: 15,
        );
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

  Map<String, dynamic> _request(
    String action, {
    int? categoryId,
    String? rideMode,
    int? passengerCount,
  }) => {
        'action': action,
        'pincode': _pin.text.trim(),
        'vehicleCategoryId': categoryId ?? _categoryId,
        'rideMode': rideMode ?? _rideMode,
        'passengerCount': (rideMode ?? _rideMode) == 'shared_auto'
            ? (passengerCount ?? _passengerCount)
            : 1,
        'pickup': _pickup!.toJson(),
        'destination': _destination!.toJson(),
      };

  Future<void> _getQuote() async {
    if (QuickRideAuth.currentUser == null) {
      setState(() => _error = 'Sign in with Google to compare ride options.');
      try {
        await QuickRideAuth.signInWithGoogle(
          redirectTo: 'in.quickride.customer://login-callback',
        );
      } catch (error) {
        if (mounted) setState(() => _error = 'Google sign-in failed: ' + error.toString());
      }
      return;
    }
    if (_pickup == null || _destination == null) {
      setState(() => _error = 'Select both pickup and destination.');
      return;
    }
    final inferredPincode = _pickup!.pincode;
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(_pin.text.trim()) &&
        inferredPincode != null) {
      _pin.text = inferredPincode;
    }
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(_pin.text.trim())) {
      setState(() => _error =
          'We could not read the pickup pincode. Enter the six-digit pickup service pincode to check availability.');
      return;
    }
    if (_categories.isEmpty) {
      setState(() => _error =
          'No active vehicle categories are configured for Quick Ride.');
      return;
    }

    await _run(() async {
      final results = <Map<String, dynamic>>[];
      final failures = <String>[];
      for (final category in _categories) {
        final id = (category['id'] as num).toInt();
        final name = category['name'].toString();
        final code = category['code'].toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        try {
          final response = await QuickRideBackend.invoke(
            'ride-booking',
            body: _request('quote', categoryId: id, rideMode: 'private'),
          );
          final data = Map<String, dynamic>.from(response.data as Map);
          final quote = Map<String, dynamic>.from(data['quote'] as Map);
          results.add({
            'category_id': id,
            'category_name': name,
            'category_code': code,
            'ride_mode': 'private',
            'passenger_count': 1,
            'quote': quote,
          });
        } catch (error) {
          failures.add(name + ': ' + error.toString());
        }

        if (code == 'auto' || code == 'autorickshaw') {
          try {
            final response = await QuickRideBackend.invoke(
              'ride-booking',
              body: _request('quote', categoryId: id, rideMode: 'shared_auto', passengerCount: _passengerCount),
            );
            final data = Map<String, dynamic>.from(response.data as Map);
            final quote = Map<String, dynamic>.from(data['quote'] as Map);
            if (quote['shared_auto'] is Map) {
              results.add({
                'category_id': id,
                'category_name': 'Shared Auto',
                'category_code': code,
                'ride_mode': 'shared_auto',
                'passenger_count': 1,
                'quote': quote,
              });
            }
          } catch (error) {
            failures.add('Shared Auto: ' + error.toString());
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _serviceQuotes = results;
        _quote = null;
        _booking = null;
        _sharedAuto = null;
        _pickupOtp = null;
        if (results.isEmpty) {
          _error = failures.isEmpty
              ? 'No ride services are configured for this pickup area.'
              : 'No ride service returned a fare. Check the pickup pincode, service-area coverage and fare configuration. ' + failures.first;
        } else {
          _error = null;
        }
      });
    });
  }

  void _selectServiceOption(Map<String, dynamic> option) {
    setState(() {
      _categoryId = (option['category_id'] as num).toInt();
      _rideMode = option['ride_mode'].toString();
      _passengerCount = 1;
      _quote = Map<String, dynamic>.from(option['quote'] as Map);
      _sharedAutoCapacity = ((_quote!['shared_auto'] as Map?)?['max_passengers'] as num?)?.toInt() ?? 3;
      _booking = null;
      _sharedAuto = null;
      _pickupOtp = null;
    });
  }

  Future<void> _bookRide() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      setState(() => _error = 'Sign in before confirming your ride.');
      try {
        await QuickRideAuth.signInWithGoogle(
          redirectTo: 'in.quickride.customer://login-callback',
        );
      } catch (error) {
        if (mounted) setState(() => _error = 'Google sign-in failed: ' + error.toString());
      }
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
                  key: const ValueKey('quick-ride-booking-map'),
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
                  onMapCreated: (map) {
                    _mapController = map;
                    final pickup = _pickup;
                    if (pickup != null) {
                      map.moveTo(
                        LatLng(pickup.latitude, pickup.longitude),
                        zoom: 15,
                      );
                    }
                  },
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
                  onChanged: (_) => setState(() {
                    _sharedAutoCapacity = 3;
                    _quote = null;
                    _sharedAuto = null;
                    _error = null;
                  }),
                  decoration: const InputDecoration(
                    labelText: 'Pickup pincode',
                    counterText: '',
                    prefixIcon: Icon(Icons.pin_drop_outlined),
                  ),
                ),
                if (_loadingCategories) const LinearProgressIndicator(),
                if (!_loadingCategories && _categories.isEmpty)
                  const Text('No vehicle services are configured yet.'),
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
                if (_serviceQuotes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('Available rides for your route',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  ..._serviceQuotes.map((option) {
                    final quote = Map<String, dynamic>.from(option['quote'] as Map);
                    final isSelected = _quote != null &&
                        _categoryId == (option['category_id'] as num).toInt() &&
                        _rideMode == option['ride_mode'];
                    final distance = (quote['distance_m'] as num?)?.toDouble() ?? 0;
                    final duration = (quote['duration_s'] as num?)?.toInt() ?? 0;
                    final shared = option['ride_mode'] == 'shared_auto';
                    return Card(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(shared
                              ? Icons.groups_2_outlined
                              : option['category_code'] == 'bike'
                                  ? Icons.two_wheeler
                                  : option['category_code'] == 'auto' ||
                                          option['category_code'] == 'autorickshaw'
                                      ? Icons.electric_rickshaw
                                      : Icons.local_taxi_outlined),
                        ),
                        title: Text(option['category_name'].toString()),
                        subtitle: Text(
                          '${(distance / 1000).toStringAsFixed(1)} km · ${(duration / 60).ceil()} min'
                          '${shared ? ' · 1 passenger' : ''}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '₹${(quote['estimated_fare'] as num).toStringAsFixed(0)}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            TextButton(
                              onPressed: _busy ? null : () => _selectServiceOption(option),
                              child: Text(isSelected ? 'Selected' : 'Choose'),
                            ),
                          ],
                        ),
                        onTap: _busy ? null : () => _selectServiceOption(option),
                      ),
                    );
                  }),
                ],
                if (_quote != null) ...[
                  const SizedBox(height: 10),
                  if (_rideMode == 'shared_auto') ...[
                    DropdownButtonFormField<int>(
                      initialValue: _passengerCount,
                      decoration: const InputDecoration(
                        labelText: 'Shared Auto passengers',
                        helperText: 'Maximum 3 passengers, subject to pincode settings.',
                      ),
                      items: [1, 2, 3]
                          .where((count) => count <= _sharedAutoCapacity)
                          .map((count) => DropdownMenuItem(
                                value: count,
                                child: Text('$count passenger${count == 1 ? '' : 's'}'),
                              ))
                          .toList(),
                      onChanged: _busy ? null : (value) {
                        if (value == null) return;
                        setState(() {
                          _passengerCount = value;
                          _quote = null;
                        });
                        unawaited(_getQuote());
                      },
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy ? null : _getQuote,
                      child: const Text('Refresh Shared Auto fare'),
                    ),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _rideMode == 'shared_auto'
                                ? 'Shared Auto · $_passengerCount passenger(s)'
                                : 'Selected ride · ${_categories.firstWhere(
                                    (item) => (item['id'] as num).toInt() == _categoryId,
                                    orElse: () => {'name': 'Ride'},
                                  )['name']}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (_rideMode == 'shared_auto')
                            const Text('Your fare is separate from other passengers’ bookings.'),
                          Text(
                            '₹${(_quote!['estimated_fare'] as num).toStringAsFixed(2)}',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          Text(
                            '${((_quote!['distance_m'] as num) / 1000).toStringAsFixed(1)} km · ${(((_quote!['duration_s'] as num) / 60).ceil())} min',
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
