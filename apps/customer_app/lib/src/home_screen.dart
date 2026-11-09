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
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final place = await QuickRideMaps.retrieveSuggestion(suggestion);
      if (!mounted) return;
      setState(() {
        if (_selectingPickup) {
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              'Where would you like to go?',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 5),
            Text(
              'Set your pickup and destination to compare available rides.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 1,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.my_location_rounded,
                        color: Color(0xFF159B65)),
                    title: const Text('PICKUP',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.1)),
                    subtitle: Text(
                      pickupLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    trailing: IconButton(
                      tooltip: 'Use current location',
                      onPressed: _loadingLocation ? null : _detectCurrentLocation,
                      icon: const Icon(Icons.gps_fixed_rounded),
                    ),
                    selected: _selectingPickup,
                    onTap: () => setState(() {
                      _selectingPickup = true;
                      _searchController.clear();
                      _suggestions = const [];
                      _error = null;
                    }),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.flag_outlined,
                        color: Color(0xFF2463EB)),
                    title: const Text('DESTINATION',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.1)),
                    subtitle: Text(
                      destinationLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _destination == null
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
                    ),
                    trailing: const Icon(Icons.edit_location_alt_outlined),
                    selected: !_selectingPickup,
                    onTap: () => setState(() {
                      _selectingPickup = false;
                      _searchController.clear();
                      _suggestions = const [];
                      _error = null;
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            textInputAction: TextInputAction.search,
                            onChanged: _onSearchChanged,
                            onSubmitted: _loadSuggestions,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search_rounded),
                              hintText: _selectingPickup
                                  ? 'Search pickup location'
                                  : 'Search destination',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
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
                  ),
                  if (_searching)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_suggestions.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _suggestions.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 56),
                        itemBuilder: (context, index) {
                          final result = _suggestions[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined),
                            title: Text(result.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(result.address,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => _chooseSuggestion(result),
                          );
                        },
                      ),
                    ),
                  if (_listening)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('Listening… speak your location'),
                    ),
                ],
              ),
            ),
            if (QuickRideCustomerPreferences.savedPlaces.value.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                'Saved places',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              ...QuickRideCustomerPreferences.savedPlaces.value.map((place) {
                final title = place['name']?.toString() ?? 'Saved place';
                final address = place['address']?.toString() ?? '';
                final latitude = (place['latitude'] as num).toDouble();
                final longitude = (place['longitude'] as num).toDouble();
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.favorite_rounded, color: Color(0xFFE45872)),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(address, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    final selected = QuickRidePlace(
                      point: LatLng(latitude, longitude),
                      name: title,
                      address: address,
                      postalCode: place['postalCode']?.toString(),
                    );
                    setState(() {
                      if (_selectingPickup) {
                        _pickup = selected;
                        _selectingPickup = false;
                      } else {
                        _destination = selected;
                      }
                    });
                    unawaited(_refreshRoute());
                  },
                );
              }),
            ],
            if (QuickRideCustomerPreferences.recentPlaces.value.isNotEmpty) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text('Recent places',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            )),
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
                final key = '$latitude,$longitude';
                final isSaved = QuickRideCustomerPreferences.savedPlaces.value.any(
                  (item) => '${item['latitude']},${item['longitude']}' == key,
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history_rounded),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(address, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: isSaved ? 'Remove favourite' : 'Save place',
                    onPressed: () async {
                      if (isSaved) {
                        await QuickRideCustomerPreferences.removeSavedPlace(place);
                      } else {
                        await QuickRideCustomerPreferences.addSavedPlace(place);
                      }
                      if (mounted) setState(() {});
                    },
                    icon: Icon(
                      isSaved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      color: isSaved ? const Color(0xFFE45872) : colors.onSurfaceVariant,
                    ),
                  ),
                  onTap: () {
                    final selected = QuickRidePlace(
                      point: LatLng(latitude, longitude),
                      name: title,
                      address: address,
                      postalCode: place['postalCode']?.toString(),
                    );
                    setState(() {
                      if (_selectingPickup) {
                        _pickup = selected;
                        _selectingPickup = false;
                      } else {
                        _destination = selected;
                      }
                    });
                    unawaited(_refreshRoute());
                  },
                );
              }),            ],
            if (_route != null) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.route_rounded),
                  title: const Text('Route preview'),
                  subtitle: Text(
                    (_route!.distanceMeters / 1000).toStringAsFixed(1) +
                        ' km · ' +
                        (_route!.durationSeconds / 60).ceil().toString() +
                        ' min estimated',
                  ),
                  trailing: _loadingRoute
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline_rounded),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _pickup != null && _destination != null
                  ? _openBooking
                  : null,
              icon: const Icon(Icons.search_rounded),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 13),
                child: Text('Choose ride'),
              ),
            ),
            const SizedBox(height: 16),
            if (_vehicleCategories.isNotEmpty) ...[
              Text(
                'Services in Quick Ride',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _vehicleCategories
                    .map((category) => Chip(
                          avatar: const Icon(Icons.local_taxi_outlined, size: 18),
                          label: Text(category['name'].toString()),
                        ))
                    .toList(growable: false),
              ),
              const SizedBox(height: 6),
              Text(
                'Exact options and fares are checked for your pickup area after you choose a destination.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 0),
    );
  }

}
