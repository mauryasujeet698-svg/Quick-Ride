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

  String model = 'subscription';
  String period = 'day';
  String? selectedAreaId;
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
    directory = await call('list');
    final areas = directory?['service_areas'] as List<dynamic>? ?? [];
    if (selectedAreaId == null && areas.isNotEmpty) {
      selectedAreaId = areas.first['id'].toString();
    }
    if (mounted) setState(() {});
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
                      return SwitchListTile(
                        value: pincode['is_active'] == true,
                        title: Text(pincode['pincode'].toString()),
                        subtitle: Text(modelName),
                        onChanged: busy ? null : (value) => setPincodeActive(pincode['id'] as int, value),
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
