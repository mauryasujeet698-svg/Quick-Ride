import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class DriverOfferScreen extends StatefulWidget {
  const DriverOfferScreen({super.key, required this.offerId});
  final String offerId;

  @override
  State<DriverOfferScreen> createState() => _DriverOfferScreenState();
}

class _DriverOfferScreenState extends State<DriverOfferScreen> {
  Map<String, dynamic>? _offer;
  Map<String, dynamic>? _ride;
  String? _error;
  bool _loading = true;
  bool _responding = false;
  DateTime _now = DateTime.now();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    unawaited(_loadOffer());
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _loadOffer() async {
    try {
      final response = await QuickRideBackend.invoke(
        'driver-ride-actions',
        body: {'action': 'get_offer_details', 'offerId': widget.offerId},
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() {
        _offer = Map<String, dynamic>.from(data['offer'] as Map);
        _ride = Map<String, dynamic>.from(data['ride'] as Map);
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  DateTime? get _expiresAt =>
      DateTime.tryParse(_offer?['expires_at']?.toString() ?? '')?.toLocal();

  int get _secondsLeft {
    final expiry = _expiresAt;
    if (expiry == null) return 0;
    return expiry.difference(_now).inSeconds.clamp(0, 3600);
  }

  String _distanceLabel(Object? value) {
    if (value is! num) return '—';
    return (value.toDouble() / 1000).toStringAsFixed(1) + ' km';
  }

  String _durationLabel(Object? value) {
    if (value is! num) return '—';
    return (value.toDouble() / 60).ceil().toString() + ' min';
  }

  Future<void> _respond(bool accept) async {
    final offer = _offer;
    final ride = _ride;
    if (_responding || offer == null || ride == null || _secondsLeft <= 0) return;
    setState(() => _responding = true);
    try {
      await QuickRideBackend.invoke(
        'driver-ride-actions',
        body: {
          'action': accept ? 'accept_offer' : 'reject_offer',
          'offerId': widget.offerId,
        },
      );
      if (!mounted) return;
      if (accept) {
        context.go(
          '/ride/${Uri.encodeComponent(ride['id'].toString())}/navigation',
        );
      } else {
        context.go('/');
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not ${accept ? 'accept' : 'reject'} this offer: $error')),
      );
      await _loadOffer();
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final expired = !_loading && _secondsLeft <= 0;
    final fare = _ride?['estimated_fare'];
    final category = _ride?['vehicle_category_name']?.toString() ?? 'Ride';
    return Scaffold(
      appBar: AppBar(
        title: const Text('New ride offer'),
        leading: IconButton(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null || _offer == null || _ride == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.hourglass_disabled_rounded, size: 52),
                        const SizedBox(height: 12),
                        Text(
                          'This ride offer is no longer available',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(_error ?? 'The offer may have expired or been assigned to another driver.'),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => context.go('/'),
                          child: const Text('Back to dashboard'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
                  children: [
                    Card(
                      color: colors.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              expired ? 'Offer expired' : 'Respond before the timer ends',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: colors.onPrimaryContainer,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              expired
                                  ? 'This request can no longer be accepted.'
                                  : '$_secondsLeft seconds remaining',
                              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                    color: colors.onPrimaryContainer,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: _secondsLeft / 90,
                              backgroundColor: colors.onPrimaryContainer.withValues(alpha: 0.15),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(category, style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            Text(
                              fare is num ? '₹${fare.toStringAsFixed(0)}' : 'Fare details pending',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.route_outlined, size: 18),
                                const SizedBox(width: 8),
                                Text(_distanceLabel(_ride!['estimated_distance_m'])),
                                const SizedBox(width: 18),
                                const Icon(Icons.schedule_outlined, size: 18),
                                const SizedBox(width: 8),
                                Text(_durationLabel(_ride!['estimated_duration_s'])),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            _LocationLine(
                              icon: Icons.trip_origin_rounded,
                              color: const Color(0xFF159B65),
                              label: 'Pickup',
                              address: _ride!['pickup_address']?.toString() ?? 'Pickup details unavailable',
                            ),
                            const Divider(height: 28),
                            _LocationLine(
                              icon: Icons.flag_rounded,
                              color: colors.primary,
                              label: 'Destination',
                              address: _ride!['destination_address']?.toString() ?? 'Destination details unavailable',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: expired || _responding ? null : () => _respond(true),
                      icon: _responding
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: const Text('Accept ride'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(58),
                        backgroundColor: const Color(0xFF17885C),
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: expired || _responding ? null : () => _respond(false),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Reject ride'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        foregroundColor: colors.error,
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _LocationLine extends StatelessWidget {
  const _LocationLine({
    required this.icon,
    required this.color,
    required this.label,
    required this.address,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String address;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(address, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      );
}
