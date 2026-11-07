import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

import 'customer_navigation_bar.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final _pin = TextEditingController();
  Timer? _lookupTimer;
  StreamSubscription<dynamic>? _authSubscription;
  List<Map<String, dynamic>> _areas = [];
  List<Map<String, dynamic>> _categories = [];
  bool _loadingAreas = false;
  bool _loadingCategories = false;
  String? _areaError;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (mounted) setState(() {});
      });
      unawaited(_loadCategories());
      unawaited(_lookupAreas(''));
    }
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    _authSubscription?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    if (!QuickRideBackend.isInitialized) return;
    setState(() => _loadingCategories = true);
    try {
      final rows = await QuickRideBackend.client
          .from('vehicle_categories')
          .select('id,code,name')
          .eq('is_active', true)
          .order('id')
          .limit(6);
      if (!mounted) return;
      setState(() => _categories = rows);
    } catch (_) {
      if (mounted) setState(() => _categories = []);
    } finally {
      if (mounted) setState(() => _loadingCategories = false);
    }
  }

  void _onPincodeChanged(String value) {
    _lookupTimer?.cancel();
    _lookupTimer = Timer(
      const Duration(milliseconds: 350),
      () => _lookupAreas(value.trim()),
    );
  }

  Future<void> _lookupAreas(String value) async {
    if (!QuickRideBackend.isInitialized) return;
    setState(() {
      _loadingAreas = true;
      _areaError = null;
    });
    try {
      var request = QuickRideBackend.client
          .from('service_area_pincodes')
          .select('pincode,label,service_areas!inner(city,state)')
          .eq('is_active', true);
      if (value.isNotEmpty) {
        request = request.like('pincode', value + '%');
      }
      final rows = await request.order('pincode').limit(8);
      if (!mounted) return;
      setState(() => _areas = rows);
    } catch (error) {
      if (!mounted) return;
      setState(() => _areaError = 'Service-area lookup is unavailable right now.');
    } finally {
      if (mounted) setState(() => _loadingAreas = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.route_rounded, color: Colors.white, size: 21),
            ),
            const SizedBox(width: 10),
            const Text('Quick-Ride', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          if (user == null)
            TextButton(
              onPressed: QuickRideBackend.isInitialized
                  ? () async => QuickRideAuth.signInWithGoogle(
                        redirectTo: 'in.quickride.customer://login-callback',
                      )
                  : null,
              child: const Text('Sign in'),
            )
          else
            IconButton(
              tooltip: 'Profile',
              onPressed: () => context.go('/profile'),
              icon: const Icon(Icons.account_circle_outlined),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: [
          Text(
            'Your ride, on your time',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            'Where are you going?',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.12,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            'Choose your pickup and destination. Check service availability before you book.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 18),
          Container(
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: colors.primary.withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.near_me_outlined, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'READY WHEN YOU ARE',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'A ride that starts with a tap.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'Set your locations, compare available vehicle options and see your fare before confirming.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 17),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: QuickRideBackend.isInitialized
                        ? () => context.push('/book')
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: colors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.directions_car_filled_outlined),
                        SizedBox(width: 8),
                        Text('Book a ride', style: TextStyle(fontWeight: FontWeight.w800)),
                        SizedBox(width: 5),
                        Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Choose your ride', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              if (_loadingCategories)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 11),
          if (_categories.isEmpty)
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.directions_car_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Vehicle options appear here when your service area is configured.'),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  final code = category['code'].toString().toLowerCase();
                  final icon = code.contains('bike') || code.contains('motor')
                      ? Icons.two_wheeler
                      : code.contains('auto')
                          ? Icons.electric_rickshaw
                          : Icons.directions_car_filled_outlined;
                  return Container(
                    width: 132,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(icon, color: colors.primary, size: 25),
                        Text(
                          category['name'].toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 22),
          Text(
            'Check service in your area',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onChanged: _onPincodeChanged,
            decoration: InputDecoration(
              hintText: 'Enter 6-digit pickup pincode',
              counterText: '',
              prefixIcon: const Icon(Icons.location_on_outlined),
              suffixIcon: _loadingAreas
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Check pincode',
                      onPressed: () => _lookupAreas(_pin.text.trim()),
                      icon: const Icon(Icons.search),
                    ),
              filled: true,
              fillColor: colors.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (_areaError != null)
            Text(_areaError!, style: TextStyle(color: colors.error))
          else if (!QuickRideBackend.isInitialized)
            Text(
              'Connect the app to the Quick-Ride service to check active pincodes.',
              style: TextStyle(color: colors.onSurfaceVariant),
            )
          else if (_areas.isEmpty && !_loadingAreas && _pin.text.length == 6)
            Text(
              'No active Quick-Ride service matches this pincode yet.',
              style: TextStyle(color: colors.onSurfaceVariant),
            )
          else if (_areas.isNotEmpty)
            ..._areas.map((area) {
              final details = area['service_areas'] as Map<String, dynamic>;
              final label = (area['label'] ?? '').toString();
              final city = details['city'].toString();
              final state = details['state'].toString();
              return Card(
                margin: const EdgeInsets.only(top: 8),
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.check_rounded, color: Colors.green)),
                  title: Text(area['pincode'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(label.isEmpty ? city + ', ' + state : label + ' · ' + city + ', ' + state),
                  trailing: const Text('Active', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w700)),
                ),
              );
            }),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.secondaryContainer,
                child: Icon(Icons.support_agent_rounded, color: colors.onSecondaryContainer),
              ),
              title: const Text('Need help with a ride?'),
              subtitle: const Text('Choose a ride and contact Quick-Ride support.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/support'),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 0),
    );
  }
}
