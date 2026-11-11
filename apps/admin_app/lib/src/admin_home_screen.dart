import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final areaName = TextEditingController();
  final city = TextEditingController();
  final state = TextEditingController();
  final pin = TextEditingController();
  final subscriptionAmount = TextEditingController();
  final commissionPercent = TextEditingController();
  final boundaryJson = TextEditingController();
  final categoryCode = TextEditingController();
  final categoryName = TextEditingController();
  final baseFare = TextEditingController();
  final perKmRate = TextEditingController();
  final perMinuteRate = TextEditingController(text: '0');
  final minimumFare = TextEditingController();
  final bookingFee = TextEditingController(text: '0');
  final fareMultiplier = TextEditingController(text: '1');

  String model = 'subscription';
  String period = 'day';
  String? selectedAreaId;
  int? selectedCategoryId;
  int? selectedPincodeId;
  List<Map<String, dynamic>> vehicleCategories = [];
  List<Map<String, dynamic>> fareConfigs = [];
  Map<String, dynamic>? directory;
  bool busy = false;
  bool _adminAuthorized = false;
  bool _signingIn = false;
  int _previewTabIndex = 0;
  String? _signInError;
  String? errorText;
  StreamSubscription<dynamic>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      if (QuickRideAuth.currentUser != null) unawaited(load());
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (!mounted) return;
        if (QuickRideAuth.currentUser != null) {
          setState(() {});
          if (directory == null && !busy) unawaited(load());
        } else {
          setState(() {
            directory = null;
            selectedAreaId = null;
            _adminAuthorized = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    areaName.dispose();
    city.dispose();
    state.dispose();
    pin.dispose();
    subscriptionAmount.dispose();
    commissionPercent.dispose();
    boundaryJson.dispose();
    categoryCode.dispose();
    categoryName.dispose();
    baseFare.dispose();
    perKmRate.dispose();
    perMinuteRate.dispose();
    minimumFare.dispose();
    bookingFee.dispose();
    fareMultiplier.dispose();
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> extra = const {}]) async {
    final result = await QuickRideBackend.invoke(
      'admin-service-areas',
      body: {'action': action, ...extra},
    );
    return Map<String, dynamic>.from(result.data as Map);
  }

  Future<void> run(Future<void> Function() task) async {
    setState(() { busy = true; errorText = null; });
    try {
      await task();
    } catch (error) {
      if (mounted) setState(() => errorText = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() async {
    await run(loadWithoutBusy);
  }

  Future<void> loadWithoutBusy() async {
    _adminAuthorized = false;
    final results = await Future.wait([
      call('list'),
      call('list_vehicle_categories'),
      call('list_fare_configs'),
    ]);
    directory = results[0];
    _adminAuthorized = true;
    vehicleCategories = (results[1]['vehicle_categories'] as List<dynamic>? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    fareConfigs = (results[2]['fare_configs'] as List<dynamic>? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final areas = directory?['service_areas'] as List<dynamic>? ?? [];
    if (selectedAreaId == null && areas.isNotEmpty) {
      selectedAreaId = areas.first['id'].toString();
    }
    final selectedAreaRows = areas
        .where((item) => item['id'].toString() == selectedAreaId)
        .toList();
    final pincodeRows = selectedAreaRows.isEmpty
        ? <dynamic>[]
        : (selectedAreaRows.first['service_area_pincodes'] as List<dynamic>? ?? []);
    final selectedPincodeStillExists = pincodeRows.any(
      (item) => (item['id'] as num).toInt() == selectedPincodeId,
    );
    if (!selectedPincodeStillExists) {
      selectedPincodeId = pincodeRows.isEmpty
          ? null
          : (pincodeRows.first['id'] as num).toInt();
    }
    final activeCategories = vehicleCategories.where((item) => item['is_active'] == true);
    if (selectedCategoryId == null || !activeCategories.any((item) => item['id'] == selectedCategoryId)) {
      selectedCategoryId = activeCategories.isEmpty
          ? null
          : (activeCategories.first['id'] as num).toInt();
    }
    if (mounted) setState(() {});
  }

  Future<void> createVehicleCategory() async {
    if (categoryCode.text.trim().isEmpty || categoryName.text.trim().isEmpty) {
      setState(() => errorText = 'Enter a category code and display name.');
      return;
    }
    await run(() async {
      final result = await call('create_vehicle_category', {
        'code': categoryCode.text.trim().toLowerCase(),
        'name': categoryName.text.trim(),
      });
      selectedCategoryId = (result['vehicle_category']['id'] as num).toInt();
      categoryCode.clear();
      categoryName.clear();
      await loadWithoutBusy();
    });
  }

  Future<void> setVehicleCategoryActive(int id, bool active) async {
    await run(() async {
      await call('set_vehicle_category_active', {
        'categoryId': id,
        'isActive': active,
      });
      await loadWithoutBusy();
    });
  }

  double _fareValue(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim());
    if (value == null || !value.isFinite) {
      throw StateError('Enter a valid $label.');
    }
    return value;
  }

  Future<void> _editDispatchConfig(Map<String, dynamic> pincode) async {
    final configs = pincode['service_area_dispatch_configs'] as List<dynamic>? ?? [];
    final current = configs.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(configs.first as Map);
    const defaults = <String, int>{
      'initial_radius_m': 2000,
      'max_radius_m': 15000,
      'radius_step_m': 2000,
      'offer_batch_size': 5,
      'offer_ttl_seconds': 15,
      'location_max_age_seconds': 45,
      'chain_pickup_distance_m': 1500,
      'chain_offer_ttl_seconds': 90,
    };
    const labels = <String, String>{
      'initial_radius_m': 'Initial driver search radius (metres)',
      'max_radius_m': 'Maximum driver search radius (metres)',
      'radius_step_m': 'Search expansion step (metres)',
      'offer_batch_size': 'Drivers offered at a time',
      'offer_ttl_seconds': 'Ride offer expiry (seconds)',
      'location_max_age_seconds': 'Maximum GPS fix age (seconds)',
      'chain_pickup_distance_m': 'Next-ride pickup distance (metres)',
      'chain_offer_ttl_seconds': 'Next-ride offer expiry (seconds)',
    };
    final fields = <String, TextEditingController>{
      for (final entry in defaults.entries)
        entry.key: TextEditingController(
          text: (current[entry.key] ?? entry.value).toString(),
        ),
    };

    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Dispatch settings · ${pincode['pincode']}'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: fields.entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: entry.value,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: labels[entry.key]),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save dispatch settings'),
            ),
          ],
        ),
      );
      if (save != true) return;

      final values = <String, int>{};
      for (final entry in fields.entries) {
        final value = int.tryParse(entry.value.text.trim());
        if (value == null) {
          throw StateError('Enter a whole number for ${labels[entry.key]}.');
        }
        values[entry.key] = value;
      }
      bool within(String key, int min, int max) =>
          values[key]! >= min && values[key]! <= max;
      if (!within('initial_radius_m', 100, 50000) ||
          !within('max_radius_m', 100, 100000) ||
          values['max_radius_m']! < values['initial_radius_m']! ||
          !within('radius_step_m', 100, 25000) ||
          !within('offer_batch_size', 1, 50) ||
          !within('offer_ttl_seconds', 5, 180) ||
          !within('location_max_age_seconds', 5, 600) ||
          !within('chain_pickup_distance_m', 100, 15000) ||
          !within('chain_offer_ttl_seconds', 10, 600)) {
        throw StateError('One or more dispatch settings are outside the permitted range. Check the values and try again.');
      }

      await run(() async {
        await call('set_dispatch_config', {
          'pincodeId': (pincode['id'] as num).toInt(),
          ...values,
        });
        await loadWithoutBusy();
      });
    } catch (error) {
      if (mounted) setState(() => errorText = error.toString());
    } finally {
      for (final controller in fields.values) {
        controller.dispose();
      }
    }
  }

  Future<void> saveFareConfig() async {
    await run(() async {
      if (selectedAreaId == null || selectedCategoryId == null) {
        throw StateError('Select a service area and an active vehicle category.');
      }
      await call('create_fare_config', {
        'serviceAreaId': int.parse(selectedAreaId!),
        if (selectedPincodeId != null) 'pincodeId': selectedPincodeId,
        'vehicleCategoryId': selectedCategoryId,
        'baseFare': _fareValue(baseFare, 'base fare'),
        'perKmRate': _fareValue(perKmRate, 'per-kilometre rate'),
        'perMinuteRate': _fareValue(perMinuteRate, 'per-minute rate'),
        'minimumFare': _fareValue(minimumFare, 'minimum fare'),
        'bookingFee': _fareValue(bookingFee, 'booking fee'),
        'multiplier': _fareValue(fareMultiplier, 'fare multiplier'),
      });
      await loadWithoutBusy();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('New fare rule published. Previous fare history is retained.')),
        );
      }
    });
  }

  Future<void> createArea() async {
    await run(() async {
      final result = await call('create_service_area', {
        'name': areaName.text.trim(),
        'city': city.text.trim(),
        'state': state.text.trim(),
      });
      selectedAreaId = result['service_area']['id'].toString();
      await loadWithoutBusy();
    });
  }

  Future<void> activateArea(int id, bool active) async {
    await run(() async {
      await call('set_service_area_active', {'serviceAreaId': id, 'isActive': active});
      await loadWithoutBusy();
    });
  }

  Future<void> savePincode() async {
    await run(() async {
      if (selectedAreaId == null) throw StateError('Create or select a service area.');
      final created = await call('create_pincode', {
        'serviceAreaId': int.parse(selectedAreaId!),
        'pincode': pin.text.trim(),
      });
      final pincode = Map<String, dynamic>.from(created['pincode'] as Map);
      final pincodeId = pincode['id'] as int;
      final config = <String, dynamic>{
        'pincodeId': pincodeId,
        'businessModel': model,
      };
      if (model == 'subscription' || model == 'hybrid') {
        config['subscriptionAmount'] = double.parse(subscriptionAmount.text.trim());
        config['subscriptionPeriod'] = period;
      }
      if (model == 'commission' || model == 'hybrid') {
        config['commissionPercent'] = double.parse(commissionPercent.text.trim());
      }
      await call('configure_commercial', config);

      final rawBoundary = boundaryJson.text.trim();
      if (rawBoundary.isNotEmpty) {
        await call('set_pincode_boundary', {
          'pincodeId': pincodeId,
          'geojson': jsonDecode(rawBoundary),
        });
      }
      await loadWithoutBusy();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
            rawBoundary.isEmpty
                ? 'Pincode and model saved. Add a GeoJSON boundary before activation.'
                : 'Pincode and model saved. Activate the parent service area, then the pincode.',
          )),
        );
      }
    });
  }

  Future<void> _configureSharedAuto(Map<String, dynamic> pincode) async {
    final configRows = pincode['shared_auto_configs'] as List<dynamic>? ?? [];
    final current = configRows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(configRows.first as Map);
    final seatCapacity = TextEditingController(text: (current['seat_capacity'] ?? 3).toString());
    final maxDetour = TextEditingController(text: (current['max_detour_percent'] ?? 40).toString());
    final maxExtraMinutes = TextEditingController(text: (current['max_extra_minutes'] ?? 15).toString());
    final fareSharePercent = TextEditingController(text: (current['fare_share_percent_per_seat'] ?? 35).toString());
    var enabled = current['is_enabled'] == true;
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text('Shared Auto · ${pincode['pincode']}'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: enabled,
                      title: const Text('Enable Shared Auto'),
                      subtitle: const Text('Auto only. Private rides remain available independently.'),
                      onChanged: (value) => setDialogState(() => enabled = value),
                    ),
                    TextField(
                      controller: seatCapacity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Maximum passengers per Auto',
                        helperText: 'Hard maximum: 3 passengers across all bookings.',
                      ),
                    ),
                    TextField(
                      controller: maxDetour,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Maximum passenger route detour (%)'),
                    ),
                    TextField(
                      controller: maxExtraMinutes,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Maximum extra travel time (minutes)'),
                    ),
                    TextField(
                      controller: fareSharePercent,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Fare share per passenger (%)',
                        helperText: 'Applied to the private fare estimate for each booking.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save settings')),
            ],
          ),
        ),
      );
      if (save != true) return;
      final capacity = int.tryParse(seatCapacity.text.trim());
      final detour = double.tryParse(maxDetour.text.trim());
      final extra = int.tryParse(maxExtraMinutes.text.trim());
      final fareShare = double.tryParse(fareSharePercent.text.trim());
      if (capacity == null || detour == null || extra == null || fareShare == null) {
        throw StateError('Enter valid numeric values for every Shared Auto setting.');
      }
      await run(() async {
        await call('configure_shared_auto', {
          'pincodeId': (pincode['id'] as num).toInt(),
          'isEnabled': enabled,
          'seatCapacity': capacity,
          'maxDetourPercent': detour,
          'maxExtraMinutes': extra,
          'fareSharePercentPerSeat': fareShare,
        });
        await loadWithoutBusy();
      });
    } finally {
      seatCapacity.dispose();
      maxDetour.dispose();
      maxExtraMinutes.dispose();
      fareSharePercent.dispose();
    }
  }

  Future<void> setPincodeVehicleEnabled(
    int pincodeId,
    int categoryId,
    bool enabled,
  ) async {
    await run(() async {
      await call('set_pincode_vehicle_enabled', {
        'pincodeId': pincodeId,
        'categoryId': categoryId,
        'isEnabled': enabled,
      });
      await loadWithoutBusy();
    });
  }

  Future<void> setPincodeActive(int id, bool active) async {
    await run(() async {
      await call('set_pincode_active', {'pincodeId': id, 'isActive': active});
      await loadWithoutBusy();
    });
  }

  Future<void> _showPreviewFeature(
    String title,
    String description,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(
          '$description\n\nPreview mode is read-only. Connect an authorised Admin account to view or change live Quick-Ride data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _previewTile(
    IconData icon,
    String title,
    String description, {
    VoidCallback? onTap,
  }) =>
      Card(
        child: ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title),
          subtitle: Text(description),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap ?? () => _showPreviewFeature(title, description),
        ),
      );

  Future<void> _signInFromPreview() async {
    if (_signingIn) return;
    if (!QuickRideBackend.isInitialized) {
      setState(() => _signInError =
          'The sign-in service is not configured in this build. Check the Supabase URL and publishable key.');
      return;
    }
    setState(() {
      _signingIn = true;
      _signInError = null;
    });
    try {
      final response = await QuickRideAuth.signInWithGoogle(
        redirectTo: 'com.quickride.admin://login-callback',
      );
      if (response.session == null || response.user == null ||
          QuickRideAuth.currentUser == null) {
        throw StateError('Google did not create an active Quick-Ride session.');
      }
    } catch (error) {
      final details = error.toString();
      final lower = details.toLowerCase();
      final message = lower.contains('canceled') || lower.contains('cancelled')
          ? 'Google sign-in was cancelled, or this Android app is missing its registered package name/SHA-1. Details: $details'
          : 'Admin sign-in failed: $details';
      if (mounted) setState(() => _signInError = message);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Widget _previewDashboard() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Platform overview', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Explore the Admin control centre. All figures in this preview are intentionally blank, not live platform data.'),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.dashboard_customize_outlined),
                    SizedBox(width: 10),
                    Text('Quick-Ride control centre'),
                    Spacer(),
                    Chip(label: Text('Preview')),
                  ]),
                  const SizedBox(height: 10),
                  const Text('A single operating console for service coverage, vehicle supply, fare rules, dispatch, driver verification and customer safety.'),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    _previewMetricChip('Rides', '—'),
                    _previewMetricChip('Captains', '—'),
                    _previewMetricChip('Service areas', '—'),
                    _previewMetricChip('Open tickets', '—'),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Start exploring', style: Theme.of(context).textTheme.titleLarge),
          _previewTile(Icons.people_alt_outlined, 'Captain management', 'Applications, vehicle details, KYC documents and operating pincode approvals.'),
          _previewTile(Icons.route_outlined, 'Ride operations', 'Live booking status, driver assignment, route progress and cancellations.'),
          _previewTile(Icons.map_outlined, 'Service coverage', 'Manage operating cities, pincodes, boundaries and active services.'),
          _previewTile(Icons.currency_rupee_outlined, 'Commercial controls', 'Configure vehicle fares, commissions, subscriptions and dispatch rules.'),
          _previewTile(Icons.support_agent_outlined, 'Customer support and safety', 'Ride-linked complaints, SOS review queue and operational follow-up.'),
          OutlinedButton.icon(
            onPressed: () => context.push('/operations'),
            icon: const Icon(Icons.monitor_heart_outlined),
            label: const Text('Explore operations dashboard'),
          ),
        ],
      );

  Widget _previewCaptains() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Captain operations', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Explore the verification and supply-management workflow. No real driver records are shown.'),
          const SizedBox(height: 12),
          _previewTile(Icons.person_add_alt_1_outlined, 'New Captain applications', 'Review profile status, submitted vehicle category and registration details.'),
          _previewTile(Icons.badge_outlined, 'KYC document review', 'Open secure driving licence, vehicle RC and insurance review flows.'),
          _previewTile(Icons.location_on_outlined, 'Service-pincode requests', 'Approve or reject applications to operate in additional pincodes.'),
          _previewTile(Icons.directions_car_outlined, 'Vehicle and category status', 'Manage available vehicle classes and whether each can be booked.'),
          _previewTile(Icons.toggle_on_outlined, 'Captain availability', 'Inspect online/offline state, latest GPS heartbeat and current assignment.'),
          _previewTile(Icons.account_balance_wallet_outlined, 'Captain settlements', 'Review subscriptions, commission entries and payout reconciliation.'),
        ],
      );

  Widget _previewRides() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Ride operations', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('The live ride board is available to authorised Admins only. These are read-only module previews.'),
          const SizedBox(height: 12),
          _previewTile(Icons.route_outlined, 'Live ride board', 'View requested, searching, offered, accepted, arriving, in-progress and completed states.'),
          _previewTile(Icons.alt_route_rounded, 'Dispatch and assignment', 'Inspect eligible Captains, offer batches, search radius, offer expiry and manual assignment.'),
          _previewTile(Icons.groups_2_outlined, 'Shared Auto operations', 'Monitor shared trips, seats, passengers, grouped pickups and detour settings.'),
          _previewTile(Icons.location_searching_outlined, 'Live map and tracking', 'Locate active trips, review route progress and inspect stale location signals.'),
          _previewTile(Icons.cancel_outlined, 'Cancellation and refunds', 'Review cancellation reasons and payment state before applying an authorised resolution.'),
          _previewTile(Icons.support_agent_outlined, 'Ride support tickets', 'Filter customer issues by active status and link each case to its ride.'),
          _previewTile(Icons.sos_outlined, 'Safety event queue', 'Review SOS events and record an internal Operations review without implying external emergency response.'),
          OutlinedButton.icon(
            onPressed: () => context.push('/operations'),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open operations preview'),
          ),
        ],
      );

  Widget _previewConfiguration() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Platform configuration', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Explore the settings that control which services can operate and how each ride is priced.'),
          const SizedBox(height: 12),
          _previewTile(Icons.location_city_outlined, 'Service areas and pincodes', 'Create operating cities, add six-digit pincodes and activate verified boundaries.'),
          _previewTile(Icons.map_outlined, 'Geographic boundaries', 'Review GeoJSON polygon coverage before activating a booking area.'),
          _previewTile(Icons.directions_car_outlined, 'Vehicle categories', 'Create and enable Bike, Auto, Car and other vehicle classes.'),
          _previewTile(Icons.currency_rupee_outlined, 'Fare rules', 'Set base fare, per-kilometre, per-minute, minimum fare and booking fee.'),
          _previewTile(Icons.business_center_outlined, 'Commercial model', 'Choose subscription, commission or hybrid terms separately per pincode.'),
          _previewTile(Icons.tune_outlined, 'Dispatch configuration', 'Adjust search radii, offer batch size, expiry, GPS freshness and ride-chain range.'),
          _previewTile(Icons.groups_2_outlined, 'Auto Sharing', 'Set seat capacity, passenger fare share, detour and extra travel time.'),
          _previewTile(Icons.local_offer_outlined, 'Service availability', 'Control which enabled vehicle categories appear in each operating pincode.'),
        ],
      );

  Widget _previewMore() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('More controls', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Additional operating tools and account controls. Sending notifications or changing any live setting requires Admin access.'),
          const SizedBox(height: 12),
          _previewTile(
            Icons.notifications_active_outlined,
            'Notification centre',
            'Compose test, targeted or limited broadcast notifications for Customer, Captain and Admin apps.',
            onTap: () => context.push('/notifications'),
          ),
          _previewTile(Icons.analytics_outlined, 'Reports and performance', 'Review ride volume, conversion, service-area performance and financial summaries.'),
          _previewTile(Icons.shield_outlined, 'Roles and permissions', 'Understand separation between Customer, Captain, Admin and Operations access.'),
          _previewTile(Icons.receipt_long_outlined, 'Admin audit history', 'Review who changed fare, service, driver-verification and dispatch settings.'),
          _previewTile(Icons.headset_mic_outlined, 'Support operations', 'Review unresolved ride tickets and record outcomes.'),
          _previewTile(Icons.settings_outlined, 'Platform settings', 'Review operating policies, app version, notifications and service-wide defaults.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _signingIn ? null : _signInFromPreview,
            icon: _signingIn
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login),
            label: Text(_signingIn ? 'Signing in…' : 'Sign in to manage Quick-Ride'),
          ),
        ],
      );

  Widget _previewMetricChip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      );

  Widget _previewPage() => switch (_previewTabIndex) {
        0 => _previewDashboard(),
        1 => _previewCaptains(),
        2 => _previewRides(),
        3 => _previewConfiguration(),
        _ => _previewMore(),
      };

  Widget _previewScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick-Ride Admin'),
        actions: [
          IconButton(
            tooltip: 'Sign in',
            onPressed: _signingIn ? null : _signInFromPreview,
            icon: const Icon(Icons.login),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_signInError != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_signInError!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
                    IconButton(
                      tooltip: 'Dismiss',
                      onPressed: () => setState(() => _signInError = null),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: _previewPage()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _previewTabIndex,
        onDestinationSelected: (index) => setState(() => _previewTabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Overview'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Captains'),
          NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'Rides'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Setup'),
          NavigationDestination(icon: Icon(Icons.more_horiz), selectedIcon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }

  Widget _authorizationPendingScreen() => Scaffold(
        appBar: AppBar(
          title: const Text('Quick-Ride Admin'),
          actions: [
            IconButton(
              tooltip: 'Sign out',
              onPressed: QuickRideAuth.signOut,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  busy ? 'Verifying Admin permissions…' : 'Admin access is required',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  busy
                      ? 'Checking your account with the protected Admin service.'
                      : (errorText ?? 'This Google account is signed in but does not have an Admin or Operations role. The project owner must grant the role securely in Supabase.'),
                  textAlign: TextAlign.center,
                ),
                if (busy) ...[
                  const SizedBox(height: 12),
                  const CircularProgressIndicator(),
                ] else ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry Admin verification'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
  @override
  Widget build(BuildContext context) {
    if (!QuickRideBackend.isInitialized ||
        QuickRideAuth.currentUser == null) {
      return _previewScreen();
    }
    if (!_adminAuthorized) return _authorizationPendingScreen();

    final areas = directory?['service_areas'] as List<dynamic>? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Operations centre'),
        actions: [
          IconButton(
            onPressed: () => context.push('/notifications'),
            icon: const Icon(Icons.notifications_active_outlined),
            tooltip: 'Notification centre',
          ),
          IconButton(onPressed: busy ? null : load, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: () => context.push('/operations'), icon: const Icon(Icons.dashboard_outlined), tooltip: 'Operations'),
          IconButton(onPressed: QuickRideAuth.signOut, icon: const Icon(Icons.logout)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Service-area management', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Set up a service area, add pincodes and configure a commercial model independently for each pincode.'),
            if (errorText != null) ...[
              const SizedBox(height: 12),
              Text(errorText!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            Text('Vehicle categories', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Create the vehicle types offered on Quick-Ride. Enable a category only when it is ready for bookings.'),
            TextField(
              controller: categoryCode,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'Category code',
                hintText: 'bike, auto, car',
                helperText: 'Lowercase letters, numbers and underscores.',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: categoryName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : createVehicleCategory,
              child: const Text('Create vehicle category'),
            ),
            if (vehicleCategories.isEmpty)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('No vehicle categories created yet.'),
                subtitle: Text('Create the categories your operating area will support.'),
              )
            else
              ...vehicleCategories.map((category) {
                final id = (category['id'] as num).toInt();
                final active = category['is_active'] == true;
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  title: Text(category['name'].toString()),
                  subtitle: Text(category['code'].toString() + (active ? ' · Available for booking' : ' · Disabled')),
                  onChanged: busy ? null : (value) => setVehicleCategoryActive(id, value),
                );
              }),
            const Divider(height: 32),
            Text('Fare rules by service area and vehicle', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Publish a new effective-dated fare rule. Existing rides keep the fare snapshot they were quoted.'),
            DropdownButtonFormField<String>(
              initialValue: selectedAreaId,
              decoration: const InputDecoration(labelText: 'Service area'),
              items: areas.map((item) {
                final area = Map<String, dynamic>.from(item as Map);
                return DropdownMenuItem(
                  value: area['id'].toString(),
                  child: Text(area['name'].toString() + ' · ' + area['city'].toString()),
                );
              }).toList(),
              onChanged: busy ? null : (value) => setState(() {
                selectedAreaId = value;
                selectedPincodeId = null;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: selectedPincodeId,
              decoration: const InputDecoration(
                labelText: 'Pincode (recommended)',
                helperText: 'A pincode-specific fare takes priority over the area fallback.',
              ),
              items: areas
                  .where((item) => item['id'].toString() == selectedAreaId)
                  .expand((item) => (item['service_area_pincodes'] as List<dynamic>? ?? []))
                  .map((item) {
                final pincode = Map<String, dynamic>.from(item as Map);
                return DropdownMenuItem<int>(
                  value: (pincode['id'] as num).toInt(),
                  child: Text(pincode['pincode'].toString() +
                      (pincode['is_active'] == true ? ' · Active' : ' · Inactive')),
                );
              }).toList(),
              onChanged: busy ? null : (value) => setState(() => selectedPincodeId = value),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: selectedCategoryId,
              decoration: const InputDecoration(labelText: 'Active vehicle category'),
              items: vehicleCategories.where((item) => item['is_active'] == true).map((item) {
                return DropdownMenuItem(
                  value: (item['id'] as num).toInt(),
                  child: Text(item['name'].toString()),
                );
              }).toList(),
              onChanged: busy ? null : (value) => setState(() => selectedCategoryId = value),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: baseFare,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Base fare (₹)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: perKmRate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate per kilometre (₹)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: perMinuteRate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate per minute (₹)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: minimumFare,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Minimum fare (₹)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bookingFee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Booking fee (₹)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: fareMultiplier,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Fare multiplier'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: busy || areas.isEmpty || selectedCategoryId == null ? null : saveFareConfig,
              child: const Text('Publish fare rule'),
            ),
            if (fareConfigs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Fare configuration history', style: Theme.of(context).textTheme.titleMedium),
              ...fareConfigs.map((fare) {
                final area = fare['service_areas'] as Map<String, dynamic>? ?? {};
                final category = fare['vehicle_categories'] as Map<String, dynamic>? ?? {};
                final active = fare['is_active'] == true;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text((area['city']?.toString() ?? area['name']?.toString() ?? 'Area') + ' · ' + (category['name']?.toString() ?? 'Vehicle')),
                  subtitle: Text(
                    'Base ₹' + (fare['base_fare'] as num).toStringAsFixed(0) +
                    ' · ₹' + (fare['per_km_rate'] as num).toStringAsFixed(0) + '/km' +
                    ' · ' + (active ? 'Active' : 'Historical'),
                  ),
                  trailing: active ? const Icon(Icons.check_circle, color: Colors.green) : const Icon(Icons.history),
                );
              }),
            ],
            const Divider(height: 32),
            Text('Create city or operating area', style: Theme.of(context).textTheme.titleLarge),
            TextField(controller: areaName, decoration: const InputDecoration(labelText: 'Area name')),
            const SizedBox(height: 8),
            TextField(controller: city, decoration: const InputDecoration(labelText: 'City')),
            const SizedBox(height: 8),
            TextField(controller: state, decoration: const InputDecoration(labelText: 'State')),
            const SizedBox(height: 8),
            FilledButton(onPressed: busy ? null : createArea, child: const Text('Create area')),
            if (areas.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Activate service area', style: Theme.of(context).textTheme.titleLarge),
              ...areas.map((item) {
                final area = Map<String, dynamic>.from(item as Map);
                final active = area['is_active'] == true;
                return SwitchListTile(
                  value: active,
                  title: Text(area['name'].toString() + ' · ' + area['city'].toString()),
                  subtitle: Text(area['state'].toString()),
                  onChanged: busy ? null : (value) => activateArea(area['id'] as int, value),
                );
              }),
              DropdownButtonFormField<String>(
                initialValue: selectedAreaId,
                decoration: const InputDecoration(labelText: 'Service area for new pincode'),
                items: areas.map((item) {
                  final area = Map<String, dynamic>.from(item as Map);
                  return DropdownMenuItem(
                    value: area['id'].toString(),
                    child: Text(area['name'].toString() + ' · ' + area['city'].toString()),
                  );
                }).toList(),
                onChanged: busy ? null : (value) => setState(() => selectedAreaId = value),
              ),
            ],
            const SizedBox(height: 24),
            Text('Pincode commercial configuration', style: Theme.of(context).textTheme.titleLarge),
            TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'Six-digit Indian pincode', counterText: ''),
            ),
            DropdownButtonFormField<String>(
              initialValue: model,
              decoration: const InputDecoration(labelText: 'Business model'),
              items: const [
                DropdownMenuItem(value: 'subscription', child: Text('Subscription')),
                DropdownMenuItem(value: 'commission', child: Text('Commission')),
                DropdownMenuItem(value: 'hybrid', child: Text('Hybrid')),
              ],
              onChanged: busy ? null : (value) => setState(() => model = value ?? 'subscription'),
            ),
            if (model != 'commission') ...[
              const SizedBox(height: 8),
              TextField(
                controller: subscriptionAmount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Subscription amount (INR)'),
              ),
              DropdownButtonFormField<String>(
                initialValue: period,
                decoration: const InputDecoration(labelText: 'Subscription billing period'),
                items: const [
                  DropdownMenuItem(value: 'day', child: Text('Daily')),
                  DropdownMenuItem(value: 'week', child: Text('Weekly')),
                  DropdownMenuItem(value: 'month', child: Text('Monthly')),
                  DropdownMenuItem(value: 'year', child: Text('Yearly')),
                ],
                onChanged: busy ? null : (value) => setState(() => period = value ?? 'day'),
              ),
            ],
            if (model != 'subscription') ...[
              const SizedBox(height: 8),
              TextField(
                controller: commissionPercent,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Commission percentage'),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: boundaryJson,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Verified GeoJSON Polygon or MultiPolygon boundary',
                helperText: 'Required to activate booking service in this pincode.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy || areas.isEmpty ? null : savePincode,
              child: const Text('Save pincode and model'),
            ),
            const SizedBox(height: 20),
            Text('Configured pincodes', style: Theme.of(context).textTheme.titleLarge),
            if (directory == null)
              OutlinedButton(onPressed: busy ? null : load, child: const Text('Load service areas'))
            else
              ...areas.map((item) {
                final area = Map<String, dynamic>.from(item as Map);
                final pins = area['service_area_pincodes'] as List<dynamic>? ?? [];
                return Card(
                  child: ExpansionTile(
                    title: Text(area['name'].toString() + ' · ' + area['city'].toString()),
                    children: pins.map((item) {
                      final pincode = Map<String, dynamic>.from(item as Map);
                      final configs = pincode['service_area_commercial_configs'] as List<dynamic>? ?? [];
                      final activeConfigs = configs.where((c) => c['is_active'] == true).toList();
                      final modelName = activeConfigs.isEmpty
                          ? 'Not configured'
                          : activeConfigs.last['business_model'].toString();
                      final dispatchRows = pincode['service_area_dispatch_configs'] as List<dynamic>? ?? [];
                      final dispatch = dispatchRows.isEmpty
                          ? <String, dynamic>{}
                          : Map<String, dynamic>.from(dispatchRows.first as Map);
                      final radiusLabel = dispatch.isEmpty
                          ? 'Default dispatch settings'
                          : '${dispatch['initial_radius_m']} m → ${dispatch['max_radius_m']} m · batch ${dispatch['offer_batch_size']}';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile(
                            value: pincode['is_active'] == true,
                            title: Text(pincode['pincode'].toString()),
                            subtitle: Text(modelName + ' · ' + radiusLabel),
                            onChanged: busy ? null : (value) => setPincodeActive(pincode['id'] as int, value),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Vehicle types in this pincode',
                                    style: Theme.of(context).textTheme.titleSmall),
                                const SizedBox(height: 4),
                                ...vehicleCategories
                                    .where((category) => category['is_active'] == true)
                                    .map((category) {
                                  final categoryId = (category['id'] as num).toInt();
                                  final mappingRows = pincode['service_area_pincode_vehicles'] as List<dynamic>? ?? [];
                                  Map<String, dynamic>? mapping;
                                  for (final row in mappingRows) {
                                    final data = Map<String, dynamic>.from(row as Map);
                                    if ((data['vehicle_category_id'] as num).toInt() == categoryId) {
                                      mapping = data;
                                      break;
                                    }
                                  }
                                  final enabled = mapping?['is_enabled'] == true;
                                  return SwitchListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(category['name'].toString()),
                                    subtitle: Text(enabled ? 'Shown to customers' : 'Hidden from customers'),
                                    value: enabled,
                                    onChanged: busy
                                        ? null
                                        : (value) => setPincodeVehicleEnabled(
                                              (pincode['id'] as num).toInt(),
                                              categoryId,
                                              value,
                                            ),
                                  );
                                }),
                              ],
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 16, bottom: 8),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed: busy ? null : () => _editDispatchConfig(pincode),
                                    icon: const Icon(Icons.tune, size: 18),
                                    label: const Text('Configure dispatch'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy ? null : () => _configureSharedAuto(pincode),
                                    icon: const Icon(Icons.groups_2_outlined, size: 18),
                                    label: const Text('Shared Auto settings'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
