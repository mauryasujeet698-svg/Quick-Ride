import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../customer_preferences.dart';

import 'customer_navigation_bar.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final _searchController = TextEditingController();
  final _speech = stt.SpeechToText();
  Timer? _searchDebounce;
  StreamSubscription<dynamic>? _authSubscription;
  LatLng? _currentPosition;
  QuickRidePlace? _pickup;
  QuickRidePlace? _destination;
  List<QuickRideSearchResult> _suggestions = const [];
  List<Map<String, dynamic>> _vehicleCategories = const [];
  QuickRideRoute? _route;
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

  Future<void> _loadVehicleCategories() async {
    try {
      final rows = await QuickRideBackend.client
          .from('vehicle_categories')
          .select('id,code,name,description')
          .eq('is_active', true)
          .order('sort_order');
      if (mounted) setState(() => _vehicleCategories = rows);
    } catch (_) {
      // The booking flow will surface the live backend error when needed.
    }
  }

  Future<void> _detectCurrentLocation() async {
    try {
      final position = await QuickRideMaps.currentPosition();
      final point = LatLng(position.latitude, position.longitude);
      String address;
      try {
        address = await QuickRideMaps.reverseGeocode(point);
      } catch (_) {
        address = 'Current location';
      }
      if (!mounted) return;
      final postalCode = RegExp(r'(?<![0-9])[1-9][0-9]{5}(?![0-9])')
          .firstMatch(address)
          ?.group(0);
      setState(() {
        _currentPosition = point;
        _pickup = QuickRidePlace(
          point: point,
          name: 'Current location',
          address: address,
          postalCode: postalCode,
        );
        _loadingLocation = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _error = 'Location is unavailable. Search for your pickup or enter it manually. ' + error.toString();
      });
    }
  }

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
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await QuickRideMaps.searchSuggestions(
        query: query,
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
    final wasSelectingPickup = _selectingPickup;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final place = await QuickRideMaps.retrieveSuggestion(suggestion);
      if (!mounted) return;
      setState(() {
        if (wasSelectingPickup) {
          _pickup = place;
          _selectingPickup = false;
        } else {
          _destination = place;
        }
        _searchController.clear();
        _suggestions = const [];
        _searching = false;
      });
      await QuickRideCustomerPreferences.addRecentPlace({
        'name': place.name,
        'address': place.address,
        'latitude': place.point.latitude,
        'longitude': place.point.longitude,
        'postalCode': place.postalCode,
      });
      if (mounted) setState(() {});
      await _refreshRoute();
      if (!wasSelectingPickup && _pickup != null && _destination != null && mounted) {
        _openBooking();
      }
    } catch (error) {
      if (mounted) setState(() {
        _searching = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refreshRoute() async {
    final origin = _pickup?.point;
    final destination = _destination?.point;
    if (origin == null || destination == null) {
      if (mounted) setState(() => _route = null);
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
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() {
        _route = null;
        _error = 'Route preview is temporarily unavailable. You can still continue to fare search. ' + error.toString();
      });
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
        'pincode': pickup.postalCode,
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
    final destinationLabel = _destination?.address ?? 'Where would you like to go?';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.route_rounded, color: Color(0xFF2463EB)),
            const SizedBox(width: 8),
            Text(
              'Quick Ride',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Profile and settings',
            onPressed: () => context.go('/profile'),
            icon: const Icon(Icons.person_outline_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  QuickRideMapView(
                    initialCenter: _currentPosition ?? const LatLng(25.4358, 81.8463),
                    initialZoom: _currentPosition == null ? 5 : 14.5,
                    currentPosition: _currentPosition,
                    pickup: _pickup?.point,
                    destination: _destination?.point,
                    routePoints: _route?.points ?? const [],
                    followCurrentPosition: false,
                  ),
                  Positioned(
                    top: 14,
                    left: 16,
                    child: Material(
                      elevation: 2,
                      borderRadius: BorderRadius.circular(22),
                      color: colors.surface,
                      child: IconButton(
                        tooltip: 'Use current location',
                        onPressed: _loadingLocation ? null : _detectCurrentLocation,
                        icon: const Icon(Icons.my_location_rounded),
                      ),
                    ),
                  ),
                  if (_loadingRoute)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_error != null && _route == null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 10,
                      child: Material(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            _error!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 6,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                children: [
                  Card(
                    elevation: 2,
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                      child: Column(
                        children: [
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.my_location_rounded,
                              color: Color(0xFF159B65),
                            ),
                            title: const Text(
                              'Pickup',
                              style: TextStyle(fontSize: 11, letterSpacing: 0.8),
                            ),
                            subtitle: Text(
                              pickupLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            trailing: IconButton(
                              tooltip: 'Change pickup',
                              onPressed: () => setState(() {
                                _selectingPickup = true;
                                _searchController.clear();
                                _suggestions = const [];
                                _error = null;
                              }),
                              icon: const Icon(Icons.edit_location_alt_outlined),
                            ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.flag_outlined,
                              color: Color(0xFF2463EB),
                            ),
                            title: const Text(
                              'Destination',
                              style: TextStyle(fontSize: 11, letterSpacing: 0.8),
                            ),
                            subtitle: Text(
                              destinationLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _destination == null
                                    ? colors.onSurfaceVariant
                                    : colors.onSurface,
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: 'Change destination',
                              onPressed: () => setState(() {
                                _selectingPickup = false;
                                _searchController.clear();
                                _suggestions = const [];
                                _error = null;
                              }),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  textInputAction: TextInputAction.search,
                                  onChanged: _onSearchChanged,
                                  onSubmitted: _loadSuggestions,
                                  decoration: InputDecoration(
                                    hintText: _selectingPickup
                                        ? 'Enter pickup location'
                                        : 'Enter destination',
                                    prefixIcon: const Icon(Icons.search_rounded),
                                    isDense: true,
                                    filled: true,
                                    fillColor: colors.surfaceContainerHighest,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: _listening ? 'Stop voice search' : 'Search by voice',
                                onPressed: _toggleMicrophone,
                                icon: Icon(
                                  _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                                ),
                              ),
                            ],
                          ),
                          if (_searching) ...[
                            const SizedBox(height: 8),
                            const LinearProgressIndicator(minHeight: 2),
                          ],
                          if (_suggestions.isNotEmpty)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 210),
                              child: ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _suggestions.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final result = _suggestions[index];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.place_outlined),
                                    title: Text(
                                      result.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      result.address,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _chooseSuggestion(result),
                                  );
                                },
                              ),
                            ),
                          if (_listening)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('Listening… speak your location'),
                            ),
                          if (_pickup != null && _destination != null) ...[
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _openBooking,
                                icon: const Icon(Icons.search_rounded),
                                label: const Text('View ride options'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (QuickRideCustomerPreferences.recentPlaces.value.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recent places',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        TextButton(
                          onPressed: QuickRideCustomerPreferences.clearRecentPlaces,
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    ...QuickRideCustomerPreferences.recentPlaces.value.map((place) {
                      final title = place['name']?.toString() ?? 'Recent place';
                      final address = place['address']?.toString() ?? '';
                      final latitude = (place['latitude'] as num).toDouble();
                      final longitude = (place['longitude'] as num).toDouble();
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history_rounded),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(address, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          final selected = QuickRidePlace(
                            point: LatLng(latitude, longitude),
                            name: title,
                            address: address,
                            postalCode: place['postalCode']?.toString(),
                          );
                          final wasSelectingPickup = _selectingPickup;
                          setState(() {
                            if (wasSelectingPickup) {
                              _pickup = selected;
                              _selectingPickup = false;
                            } else {
                              _destination = selected;
                            }
                          });
                          unawaited(() async {
                            await _refreshRoute();
                            if (!wasSelectingPickup && _pickup != null && _destination != null && mounted) {
                              _openBooking();
                            }
                          }());
                        },
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 0),
    );
  }

}
