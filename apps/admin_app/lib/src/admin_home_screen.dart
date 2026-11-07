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
  List<Map<String, dynamic>> vehicleCategories = [];
  List<Map<String, dynamic>> fareConfigs = [];
  Map<String, dynamic>? directory;
  bool busy = false;
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
    final results = await Future.wait([
      call('list'),
      call('list_vehicle_categories'),
      call('list_fare_configs'),
    ]);
    directory = results[0];
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

  Future<void> setPincodeActive(int id, bool active) async {
    await run(() async {
      await call('set_pincode_active', {'pincodeId': id, 'isActive': active});
      await loadWithoutBusy();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!QuickRideBackend.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick-Ride Admin')),
        body: const Center(child: Text('Supabase URL and anon key are required at build time.')),
      );
    }
    if (QuickRideAuth.currentUser == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick-Ride Admin')),
        body: Center(
          child: FilledButton.icon(
            onPressed: () => QuickRideAuth.signInWithGoogle(
              redirectTo: 'in.quickride.admin://login-callback',
            ),
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google'),
          ),
        ),
      );
    }

    final areas = directory?['service_areas'] as List<dynamic>? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Operations centre'),
        actions: [
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
              onChanged: busy ? null : (value) => setState(() => selectedAreaId = value),
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 16, bottom: 8),
                              child: TextButton.icon(
                                onPressed: busy ? null : () => _editDispatchConfig(pincode),
                                icon: const Icon(Icons.tune, size: 18),
                                label: const Text('Configure dispatch'),
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
