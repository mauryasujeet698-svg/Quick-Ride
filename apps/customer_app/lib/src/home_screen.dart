import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../customer_preferences.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import 'customer_navigation_bar.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final _searchController = TextEditingController();
  final _speech = stt.SpeechToText();
  final _random = Random.secure();
  Timer? _searchDebounce;
  StreamSubscription<dynamic>? _authSubscription;
  mbx.MapboxMap? _map;
  LatLng? _currentPosition;
  QuickRidePlace? _pickup;
  QuickRidePlace? _destination;
  List<QuickRideSearchResult> _suggestions = const [];
  List<Map<String, dynamic>> _vehicleCategories = const [];
  List<LatLng> _routePoints = const [];
  QuickRideRoute? _route;
  String? _searchSession;
  String? _error;
  bool _loadingLocation = true;
  bool _searching = false;
  bool _listening = false;
  bool _selectingPickup = false;
  bool _loadingRoute = false;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (mounted) setState(() {});
      });
      unawaited(_loadVehicleCategories());
    }
    // The first launch requests foreground location. If declined, users can
    // still set pickup and destination by searching or tapping the map.
    unawaited(_detectCurrentLocation());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _authSubscription?.cancel();
    _searchController.dispose();
    unawaited(_speech.cancel());
    super.dispose();
  }

  String _newSearchSession() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _loadVehicleCategories() async {
    try {
      final rows = await QuickRideBackend.client
          .from('vehicle_categories')
          .select('id,code,name,description')
          .eq('is_active', true)
          .order('sort_order')
          .limit(5);
      if (mounted) setState(() => _vehicleCategories = rows);
    } catch (_) {
      // The booking flow will surface the live backend error when needed.
    }
  }

  Future<void> _detectCurrentLocation() async {
    try {
      final position = await QuickRideMaps.currentPosition();
      final point = LatLng(position.latitude, position.longitude);
      final address = await QuickRideMaps.reverseGeocode(point);
      if (!mounted) return;
      setState(() {
        _currentPosition = point;
        _pickup = QuickRidePlace(point: point, name: 'Current location', address: address);
        _loadingLocation = false;
        _error = null;
      });
      final map = _map;
      if (map != null) {
        await map.flyTo(_cameraOptions(point, 15), _animationOptions());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _error = 'Location is unavailable. Search for your pickup or choose a point on the map.';
      });
    }
  }

  mbx.CameraOptions _cameraOptions(LatLng point, double zoom) =>
      mbx.CameraOptions(
        center: mbx.Point(
          coordinates: mbx.Position(point.longitude, point.latitude),
        ),
        zoom: zoom,
      );

  mbx.MapAnimationOptions _animationOptions() =>
      mbx.MapAnimationOptions(duration: 650);

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().length < 2) {
      setState(() => _suggestions = const []);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _loadSuggestions(value),
    );
  }

  Future<void> _loadSuggestions(String query) async {
    final session = _searchSession ??= _newSearchSession();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await QuickRideMaps.searchSuggestions(
        query: query,
        sessionToken: session,
        proximity: _currentPosition,
      );
      if (!mounted) return;
      setState(() => _suggestions = results);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _chooseSuggestion(QuickRideSearchResult suggestion) async {
    final session = _searchSession;
    if (session == null) return;
    setState(() {
      _searching = true;
      _suggestions = const [];
      _error = null;
    });
    try {
      final place = await QuickRideMaps.retrieveSearchResult(
        mapboxId: suggestion.mapboxId,
        sessionToken: session,
      );
      if (!mounted) return;
      setState(() {
        if (_selectingPickup) {
          _pickup = place;
        } else {
          _destination = place;
        }
        _searchSession = null;
        _searchController.clear();
      });
      final map = _map;
      if (map != null) {
        map.flyTo(
          _mapCamera(place.point, 15.5),
          _mapAnimation(),
        );
      }
      await _refreshRoute();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  mbx.CameraOptions _mapCamera(LatLng point, double zoom) =>
      _cameraOptions(point, zoom);

  mbx.MapAnimationOptions _mapAnimation() => _animationOptions();

  Future<void> _selectMapPoint(LatLng point) async {
    if (point.latitude < 6 || point.latitude > 38 ||
        point.longitude < 68 || point.longitude > 98) {
      setState(() => _error = 'Please choose a location in India.');
      return;
    }
    setState(() {
      _loadingRoute = true;
      _error = null;
    });
    try {
      final address = await QuickRideMaps.reverseGeocode(point);
      final place = QuickRidePlace(
        point: point,
        name: _selectingPickup ? 'Pickup location' : 'Destination',
        address: address,
      );
      setState(() {
        if (_selectingPickup) {
          _pickup = place;
          _pickupSummary = address;
        } else {
          _destination = place;
        }
      });
      await _refreshRoute();
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _refreshRoute() async {
    final origin = _pickup?.point;
    final destination = _destination?.point;
    if (origin == null || destination == null) {
      if (mounted) setState(() {
        _route = null;
        _routePoints = const [];
      });
      return;
    }
    setState(() => _loadingRoute = true);
    try {
      final route = await QuickRideMaps.drivingRoute(
        origin: origin,
        destination: destination,
      );
      if (!mounted) return;
      setState(() {
        _route = route;
        _routePoints = route.points;
      });
      // QuickRideMapView automatically fits the complete Mapbox route.
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _toggleMicrophone() async {
    if (_speech.isListening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ready = await _speech.initialize(
      onStatus: (status) {
        if (mounted) setState(() => _listening = status == 'listening');
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _listening = false;
            _error = 'Voice search is unavailable. You can type your destination instead.';
          });
        }
      },
    );
    if (!ready) {
      if (mounted) {
        setState(() => _error = 'Microphone permission or speech recognition is unavailable.');
      }
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: QuickRideCustomerPreferences.locale.value.languageCode == 'hi' ? 'hi_IN' : 'en_IN',
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (result) {
        _searchController.text = result.recognizedWords;
        _searchController.selection = TextSelection.collapsed(
          offset: _searchController.text.length,
        );
        if (result.finalResult) {
          _onSearchChanged(result.recognizedWords);
        }
        if (mounted) setState(() {});
      },
    );
  }

  void _openBooking() {
    final pickup = _pickup;
    final destination = _destination;
    if (pickup == null || destination == null) {
      setState(() => _error = 'Select both pickup and destination to continue.');
      return;
    }
    context.push('/book', extra: {
      'pickup': {
        'longitude': pickup.point.longitude,
        'latitude': pickup.point.latitude,
        'address': pickup.address,
      },
      'destination': {
        'longitude': destination.point.longitude,
        'latitude': destination.point.latitude,
        'address': destination.address,
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pickupLabel = _pickup?.address ??
        (_loadingLocation ? 'Detecting your location…' : 'Choose pickup location');
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: QuickRideMapView(
              key: const ValueKey('quick-ride-customer-home-map'),
              initialCenter: _currentPosition ?? const LatLng(20.5937, 78.9629),
              initialZoom: _currentPosition == null ? 4.6 : 15,
              currentPosition: _currentPosition,
              pickup: _pickup?.point,
              destination: _destination?.point,
              routePoints: _routePoints,
              onMapCreated: (map) {
                _map = map;
                final current = _currentPosition;
                if (current != null) {
                  unawaited(map.flyTo(_cameraOptions(current, 15), _animationOptions()));
                }
              },
              onTap: _selectMapPoint,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: const [
                            BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 4)),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.route_rounded, color: Color(0xFF2463EB), size: 22),
                            const SizedBox(width: 8),
                            Text('Quick Ride', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: colors.surface,
                        shape: const CircleBorder(),
                        elevation: 3,
                        child: IconButton(
                          tooltip: 'Profile and settings',
                          onPressed: () => context.go('/profile'),
                          icon: const Icon(Icons.person_outline_rounded),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: colors.surface,
                    elevation: 5,
                    borderRadius: BorderRadius.circular(22),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                      child: Column(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(() {
                              _selectingPickup = true;
                              _searchController.clear();
                              _suggestions = const [];
                            }),
                            child: Row(
                              children: [
                                const Icon(Icons.my_location, color: Color(0xFF159B65)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('PICKUP', style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.0)),
                                      Text(
                                        pickupLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Use current location',
                                  onPressed: _detectCurrentLocation,
                                  icon: const Icon(Icons.gps_fixed_rounded),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 15),
                          Row(
                            children: [
                              const Icon(Icons.search_rounded, color: Color(0xFF2463EB)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  textInputAction: TextInputAction.search,
                                  onChanged: _onSearchChanged,
                                  onSubmitted: _loadSuggestions,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: _selectingPickup
                                        ? 'Search pickup location'
                                        : 'Where would you like to go?',
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: _listening ? 'Stop voice search' : 'Search by voice',
                                onPressed: _toggleMicrophone,
                                icon: Icon(
                                  _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                                  color: _listening ? colors.error : colors.primary,
                                ),
                              ),
                            ],
                          ),
                          if (_listening)
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Listening… speak your destination', style: TextStyle(color: Color(0xFF2463EB), fontSize: 12)),
                            ),
                          if (_searching)
                            const LinearProgressIndicator(minHeight: 2),
                          if (_suggestions.isNotEmpty)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 220),
                              child: ListView.separated(
                                shrinkWrap: true,
                                itemCount: _suggestions.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final result = _suggestions[index];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.place_outlined),
                                    title: Text(result.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(result.address, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    onTap: () => _chooseSuggestion(result),
                                  );
                                },
                              ),
                            ),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => setState(() {
                                  _selectingPickup = true;
                                  _searchController.clear();
                                  _suggestions = const [];
                                }),
                                icon: Icon(Icons.trip_origin, color: _selectingPickup ? colors.primary : colors.onSurfaceVariant),
                                label: const Text('Set pickup'),
                              ),
                              TextButton.icon(
                                onPressed: () => setState(() {
                                  _selectingPickup = false;
                                  _searchController.clear();
                                  _suggestions = const [];
                                }),
                                icon: Icon(Icons.flag_outlined, color: !_selectingPickup ? colors.primary : colors.onSurfaceVariant),
                                label: const Text('Set destination'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 235,
            child: FloatingActionButton.small(
              heroTag: 'customer-map-recenter',
              onPressed: _detectCurrentLocation,
              child: const Icon(Icons.my_location_rounded),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 78,
            child: Material(
              color: colors.surface,
              elevation: 7,
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.route_rounded, color: Color(0xFF2463EB)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _destination?.name ?? 'Choose your destination',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (_loadingRoute)
                          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ),
                    if (_route != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${(_route!.distanceMeters / 1000).toStringAsFixed(1)} km  •  ${(_route!.durationSeconds / 60).ceil()} min estimated',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_vehicleCategories.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: _vehicleCategories.map((category) => Chip(
                          avatar: const Icon(Icons.directions_car_filled_outlined, size: 16),
                          label: Text(category['name'].toString()),
                          visualDensity: VisualDensity.compact,
                        )).toList(),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Text(_error!, style: TextStyle(color: colors.error, fontSize: 12)),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _pickup != null && _destination != null && !_loadingRoute
                            ? _openBooking
                            : null,
                        child: const Text('Choose ride'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 0),
    );
  }
}
