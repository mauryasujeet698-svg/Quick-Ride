import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'collapsible_map_sliver.dart';


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
  const CustomerBookingScreen({
    super.key,
    this.initialPickup,
    this.initialDestination,
    this.initialVehicleCategoryId,
    this.initialVehicleCategoryCode,
  });
  final RidePoint? initialPickup;
  final RidePoint? initialDestination;
  final int? initialVehicleCategoryId;
  final String? initialVehicleCategoryCode;
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
  List<LatLng> _previewRoutePoints = const [];
  bool _loadingPreviewRoute = false;
  int _mapRecenterSignal = 0;

  @override
  void initState() {
    super.initState();
    _pickup = widget.initialPickup;
    _destination = widget.initialDestination;
    _pin.text = widget.initialPickup?.pincode ?? '';
    _selectPickup = _pickup == null;
    unawaited(_loadCategories());
    if (_pickup == null) unawaited(_tryCurrentLocation());
    if (_pickup != null && _destination != null) unawaited(_refreshPreviewRoute());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final pickupPincode = _pin.text.trim().isNotEmpty
          ? _pin.text.trim()
          : (_pickup?.pincode ??
              RegExp(r'(?<![0-9])[1-9][0-9][0-9][0-9][0-9][0-9](?![0-9])')
                  .firstMatch(_pickup?.address ?? '')
                  ?.group(0) ??
              '');
      if (!RegExp(r'^[1-9][0-9][0-9][0-9][0-9][0-9]$').hasMatch(pickupPincode)) {
        if (!mounted) return;
        setState(() {
          _categories = [];
          _serviceQuotes = [];
          _loadingCategories = false;
          _error = 'We could not read the pickup pincode. Choose a pickup inside a configured service area.';
        });
        return;
      }
      _pin.text = pickupPincode;
      final pincode = await QuickRideBackend.client
          .from('service_area_pincodes')
          .select('id')
          .eq('pincode', pickupPincode)
          .eq('is_active', true)
          .maybeSingle();
      if (pincode == null) {
        if (!mounted) return;
        setState(() {
          _categories = [];
          _serviceQuotes = [];
          _loadingCategories = false;
          _error = 'Quick Ride is not active in pickup pincode ' + pickupPincode + ' yet.';
        });
        return;
      }
      final mappings = await QuickRideBackend.client
          .from('service_area_pincode_vehicles')
          .select('vehicle_categories!inner(id,code,name,description,sort_order)')
          .eq('pincode_id', (pincode['id'] as num).toInt())
          .eq('is_enabled', true);
      final categories = mappings
          .where((row) => row['vehicle_categories'] is Map)
          .map((row) => Map<String, dynamic>.from(row['vehicle_categories'] as Map))
          .toList()
        ..sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 0)
            .compareTo((b['sort_order'] as num?)?.toInt() ?? 0));
      if (!mounted) return;
      setState(() {
        _categories = categories;
        final preferredCategory = categories.where((category) {
          final idMatches = widget.initialVehicleCategoryId != null &&
              (category['id'] as num).toInt() == widget.initialVehicleCategoryId;
          final codeMatches = widget.initialVehicleCategoryCode != null &&
              category['code'].toString().toLowerCase() ==
                  widget.initialVehicleCategoryCode!.toLowerCase();
          return idMatches || codeMatches;
        }).firstOrNull;
        _categoryId = preferredCategory == null
            ? (categories.isEmpty ? null : (categories.first['id'] as num).toInt())
            : (preferredCategory['id'] as num).toInt();
        _serviceQuotes = categories.map((category) => <String, dynamic>{
          'category_id': category['id'],
          'category_name': category['name'],
          'category_code': category['code'],
          'ride_mode': 'private',
          'quote': null,
          'quote_status': 'not_checked',
        }).toList(growable: false);
        _loadingCategories = false;
        _error = categories.isEmpty
            ? 'No vehicle categories are enabled for pickup pincode ' + pickupPincode + '.'
            : null;
      });
      if (QuickRideAuth.currentUser != null &&
          _pickup != null &&
          _destination != null &&
          categories.isNotEmpty) {
        unawaited(_getQuote());
      }
    } catch (error) {
      if (mounted) setState(() {
        _categories = [];
        _serviceQuotes = [];
        _loadingCategories = false;
        _error = 'Vehicle options could not be loaded: ' + error.toString();
      });
    }
  }

  Future<void> _refreshPreviewRoute() async {
    final pickup = _pickup;
    final destination = _destination;
    if (pickup == null || destination == null) {
      if (mounted) setState(() => _previewRoutePoints = const []);
      return;
    }
    if (mounted) setState(() => _loadingPreviewRoute = true);
    try {
      final route = await QuickRideMaps.drivingRoute(
        origin: LatLng(pickup.latitude, pickup.longitude),
        destination: LatLng(destination.latitude, destination.longitude),
      );
      if (mounted) setState(() => _previewRoutePoints = route.points);
    } catch (error) {
      // A route-preview failure should not block quote/fare retrieval.
      debugPrint('Quick-Ride route preview unavailable: $error');
      if (mounted) setState(() => _previewRoutePoints = const []);
    } finally {
      if (mounted) setState(() => _loadingPreviewRoute = false);
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
          _mapRecenterSignal += 1;
          if (pincode != null) _pin.text = pincode;
        } else {
          _destination = point;
        }
        _quote = null;
      });
      if (pickup) unawaited(_loadCategories());
      if (_pickup != null && _destination != null) unawaited(_refreshPreviewRoute());
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
    if (geometryValue is! Map) return _previewRoutePoints;
    final geometry = Map<String, dynamic>.from(geometryValue);
    final rawCoordinates = geometry['coordinates'];
    if (rawCoordinates is! List) return _previewRoutePoints;
    final points = rawCoordinates
        .whereType<List>()
        .where((pair) =>
            pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map((pair) => LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ))
        .toList(growable: false);
    return points.length >= 2 ? points : _previewRoutePoints;
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
      setState(() => _error = 'Sign in with Google to check fares and nearby drivers.');
      try {
        await QuickRideAuth.signInWithGoogle(
          redirectTo: 'in.quickride.customer://login-callback',
        );
      } catch (error) {
        final details = error.toString().toLowerCase();
        final message = details.contains('canceled') || details.contains('cancelled')
            ? 'Google sign-in was cancelled. You can try again when ready.'
            : 'Google sign-in failed: ' + error.toString();
        if (mounted) setState(() => _error = message);
        return;
      }
      if (QuickRideAuth.currentUser == null) {
        if (mounted) setState(() => _error = 'Google sign-in did not complete. Please try again.');
        return;
      }
    }
    if (_pickup == null || _destination == null) {
      setState(() => _error = 'Select both pickup and destination.');
      return;
    }
    final inferredPincode = _pickup!.pincode ??
        RegExp(r'(?<![0-9])[1-9][0-9][0-9][0-9][0-9][0-9](?![0-9])')
            .firstMatch(_pickup!.address)
            ?.group(0);
    if (!RegExp(r'^[1-9][0-9][0-9][0-9][0-9][0-9]$').hasMatch(_pin.text.trim()) &&
        inferredPincode != null) {
      _pin.text = inferredPincode;
    }
    if (!RegExp(r'^[1-9][0-9][0-9][0-9][0-9][0-9]$').hasMatch(_pin.text.trim())) {
      setState(() => _error =
          'We could not read the pickup pincode. Choose a pickup inside a configured service area.');
      return;
    }
    if (_categories.isEmpty) {
      await _loadCategories();
    }
    if (_categories.isEmpty) {
      setState(() => _error = 'No vehicle categories are enabled for this pickup area.');
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
            'quote_status': 'quoted',
          });
          if (code == 'auto' || code == 'autorickshaw') {
            try {
              final sharedResponse = await QuickRideBackend.invoke(
                'ride-booking',
                body: _request(
                  'quote',
                  categoryId: id,
                  rideMode: 'shared_auto',
                  passengerCount: _passengerCount,
                ),
              );
              final sharedData = Map<String, dynamic>.from(sharedResponse.data as Map);
              final sharedQuote = Map<String, dynamic>.from(sharedData['quote'] as Map);
              if (sharedQuote['shared_auto'] is Map) {
                results.add({
                  'category_id': id,
                  'category_name': 'Shared Auto',
                  'category_code': code,
                  'ride_mode': 'shared_auto',
                  'passenger_count': 1,
                  'quote': sharedQuote,
                  'quote_status': 'quoted',
                });
              }
            } catch (_) {
              // Shared Auto is an optional mode; private Auto stays visible.
            }
          }
        } catch (error) {
          failures.add(name + ': ' + error.toString());
          results.add({
            'category_id': id,
            'category_name': name,
            'category_code': code,
            'ride_mode': 'private',
            'passenger_count': 1,
            'quote': null,
            'quote_status': 'fare_unavailable',
            'error': error.toString(),
          });
        }
      }
      if (!mounted) return;
      setState(() {
        _serviceQuotes = results;
        _quote = null;
        _booking = null;
        _sharedAuto = null;
        _pickupOtp = null;
        _error = results.every((item) => item['quote'] == null)
            ? (failures.isEmpty
                ? 'Vehicle types are listed, but fares are not configured yet.'
                : 'Vehicle types are listed, but fares could not be loaded. ' + failures.first)
            : null;
      });
    });
  }

  void _selectServiceOption(Map<String, dynamic> option) {
    setState(() {
      _categoryId = (option['category_id'] as num).toInt();
      _rideMode = option['ride_mode'].toString();
      _passengerCount = 1;
      _quote = option['quote'] is Map
          ? Map<String, dynamic>.from(option['quote'] as Map)
          : null;
      _sharedAutoCapacity = ((_quote?['shared_auto'] as Map?)?['max_passengers'] as num?)?.toInt() ?? 3;
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
    if (_quote == null) {
      setState(() => _error = 'Search again to get a fare before booking.');
      return;
    }
    final availability = _quote!['availability'] as Map<String, dynamic>?;
    final availableCount = (availability?['available_count'] as num?)?.toInt() ?? 0;
    if (availableCount <= 0) {
      setState(() => _error = 'No vehicle found for this ride type right now. Search again or choose another vehicle.');
      return;
    }
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
      body: CustomScrollView(
        slivers: [
          CollapsibleMapSliver(
            child: SizedBox.expand(
              child: Stack(
              children: [
                QuickRideMapView(
                  key: const ValueKey('quick-ride-booking-map'),
                  initialCenter: _pickup == null
                      ? const LatLng(25.45, 81.85)
                      : LatLng(_pickup!.latitude, _pickup!.longitude),
                  initialZoom: 13.5,
                  cameraTarget: _pickup == null
                      ? null
                      : LatLng(_pickup!.latitude, _pickup!.longitude),
                  recenterSignal: _mapRecenterSignal,
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
          ),
          SliverToBoxAdapter(
            child: ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
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
                      : Text(_serviceQuotes.isEmpty
                          ? 'Load vehicle options'
                          : _quote != null
                              ? 'Search again'
                              : 'Search for selected vehicle'),
                ),
                if (_serviceQuotes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Choose your vehicle',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'All enabled vehicle types are shown. Driver availability is checked separately.',
                  ),
                  const SizedBox(height: 8),
                  ..._serviceQuotes.map((option) {
                    final quoteValue = option['quote'];
                    final quote = quoteValue is Map
                        ? Map<String, dynamic>.from(quoteValue)
                        : null;
                    final isSelected =
                        _categoryId == (option['category_id'] as num).toInt() &&
                        _rideMode == option['ride_mode'];
                    final distance = (quote?['distance_m'] as num?)?.toDouble();
                    final duration = (quote?['duration_s'] as num?)?.toInt();
                    final availability = quote?['availability'] is Map
                        ? Map<String, dynamic>.from(quote!['availability'] as Map)
                        : null;
                    final nearbyCount =
                        (availability?['available_count'] as num?)?.toInt();
                    final shared = option['ride_mode'] == 'shared_auto';
                    final statusLabel = quote == null
                        ? (QuickRideAuth.currentUser == null
                            ? 'Sign in to check fare and drivers'
                            : 'Fare not configured yet')
                        : nearbyCount == 0
                            ? 'No vehicle found · Select and search again'
                            : nearbyCount == null
                                ? 'Driver availability not confirmed'
                                : nearbyCount.toString() + ' nearby driver(s)';
                    final fareLabel = quote == null
                        ? 'Fare pending'
                        : '₹' +
                            (quote['estimated_fare'] as num).toStringAsFixed(0);
                    final detail = <String>[
                      if (distance != null && duration != null)
                        (distance / 1000).toStringAsFixed(1) +
                            ' km · ' +
                            (duration / 60).ceil().toString() +
                            ' min',
                      if (shared) 'Shared ride',
                      statusLabel,
                    ].join('\n');
                    return Card(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(
                            shared
                                ? Icons.groups_2_outlined
                                : option['category_code'] == 'bike'
                                    ? Icons.two_wheeler
                                    : option['category_code'] == 'auto' ||
                                            option['category_code'] == 'autorickshaw'
                                        ? Icons.electric_rickshaw
                                        : option['category_code'] == 'suv'
                                            ? Icons.airport_shuttle_outlined
                                            : Icons.local_taxi_outlined,
                          ),
                        ),
                        title: Text(option['category_name'].toString()),
                        subtitle: Text(
                          detail,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: quote != null && nearbyCount == 0
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              fareLabel,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _selectServiceOption(option),
                              child: Text(isSelected ? 'Selected' : 'Choose'),
                            ),
                          ],
                        ),
                        onTap: _busy ? null : () => _selectServiceOption(option),
                      ),
                    );
                  }),
                  if (QuickRideAuth.currentUser == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _getQuote,
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Sign in to check fares'),
                    ),
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
                          Builder(
                            builder: (context) {
                              final available = ((_quote!['availability'] as Map?)?['available_count'] as num?)?.toInt() ?? 0;
                              return FilledButton(
                                onPressed: _busy
                                    ? null
                                    : available > 0
                                        ? _bookRide
                                        : _getQuote,
                                child: Text(available > 0
                                    ? 'Confirm booking'
                                    : 'Search for this vehicle again'),
                              );
                            },
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
