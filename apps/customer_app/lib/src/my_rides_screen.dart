import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';


class CustomerRidesScreen extends StatefulWidget {
  const CustomerRidesScreen({super.key});

  @override
  State<CustomerRidesScreen> createState() => _CustomerRidesScreenState();
}

class _CustomerRidesScreenState extends State<CustomerRidesScreen> {
  StreamSubscription<dynamic>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (!QuickRideBackend.isInitialized) {
      return const Scaffold(body: Center(child: Text('Quick-Ride backend is not configured.')));
    }
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Rides')),
        body: _SignInPrompt(
          message: 'Sign in with Google to view your ride history.',
        ),
        );
    }

    final stream = QuickRideBackend.client
        .from('rides')
        .stream(primaryKey: ['id'])
        .eq('customer_id', user.id);

    return Scaffold(
      appBar: AppBar(title: const Text('My Rides')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: const Text('Ride history is temporarily unavailable.'),
            ));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snapshot.data!.toList()
            ..sort((a, b) => b['created_at'].toString().compareTo(a['created_at'].toString()));
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.route_outlined, size: 54, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Your rides will appear here', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 7),
                    const Text('Once you book your first ride, you can follow its status here.'),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => context.go('/book'),
                      icon: const Icon(Icons.directions_car_outlined),
                      label: const Text('Book a ride'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _RideCard(ride: rows[index]),
          );
        },
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  const _RideCard({required this.ride});

  final Map<String, dynamic> ride;

  @override
  Widget build(BuildContext context) {
    final id = ride['id'].toString();
    final status = ride['status'].toString();
    final active = ['requested','searching','offered','accepted','driver_arriving','arrived','in_progress'].contains(status);
    final canCancel = ['requested','searching','offered','accepted','driver_arriving','arrived'].contains(status);
    final fare = ride['final_fare'] ?? ride['estimated_fare'];
    final created = DateTime.tryParse(ride['created_at'].toString());
    final dateLabel = created == null ? '' : created.toLocal().toString().substring(0, 16);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(active ? Icons.local_taxi_rounded : Icons.route_rounded,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Ride ' + id.substring(0, id.length < 8 ? id.length : 8),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ),
                Chip(label: Text(status.replaceAll('_', ' '))),
              ],
            ),
            if (dateLabel.isNotEmpty) Text(dateLabel, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            _RouteLine(icon: Icons.trip_origin_rounded, label: ride['pickup_address'].toString(), color: Colors.green),
            const SizedBox(height: 7),
            _RouteLine(icon: Icons.location_on_rounded, label: ride['destination_address'].toString(), color: Colors.red),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Fare', style: Theme.of(context).textTheme.bodyMedium),
                Text(
                  fare == null ? 'Pending' : '₹' + (fare as num).toStringAsFixed(0),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (active)
                  FilledButton.icon(
                    onPressed: () => context.push('/ride/' + Uri.encodeComponent(id)),
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('Track ride'),
                  ),
                if (!active)
                  OutlinedButton.icon(
                    onPressed: () => _bookAgain(context, id),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    label: const Text('Book again'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => context.push('/support?rideId=' + Uri.encodeComponent(id)),
                  icon: const Icon(Icons.support_agent_outlined, size: 18),
                  label: const Text('Get help'),
                ),
                if (canCancel)
                  TextButton(
                    onPressed: () => _cancel(context, id),
                    child: const Text('Cancel ride'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _bookAgain(BuildContext context, String id) async {
    try {
      final response = await QuickRideBackend.invoke(
        'ride-booking',
        body: {'action': 'rebook_details', 'rideId': id},
      );
      final payload = Map<String, dynamic>.from(response.data as Map);
      final rebook = Map<String, dynamic>.from(payload['rebook'] as Map);
      if (!context.mounted) return;
      await context.push('/book', extra: {
        'pickup': Map<String, dynamic>.from(rebook['pickup'] as Map),
        'destination': Map<String, dynamic>.from(rebook['destination'] as Map),
        'vehicleCategoryId': (rebook['vehicle_category_id'] as num).toInt(),
      });
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not prepare this ride again. Please try again.')),
        );
      }
    }
  }

  Future<void> _cancel(BuildContext context, String id) async {
    const reasons = <String, String>{
      'customer_changed_mind': 'I changed my mind',
      'driver_taking_too_long': 'The driver is taking too long',
      'pickup_or_destination_changed': 'Pickup or destination changed',
      'booked_by_mistake': 'I booked by mistake',
      'other': 'Other reason',
    };
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Why are you cancelling?', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 8),
              ...reasons.entries.map((entry) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.radio_button_unchecked),
                    title: Text(entry.value),
                    onTap: () => Navigator.of(sheetContext).pop(entry.key),
                  )),
            ],
          ),
        ),
      ),
    );
    if (reason == null) return;
    try {
      await QuickRideBackend.invoke(
        'ride-booking',
        body: {'action': 'cancel', 'rideId': id, 'reason': reason},
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cancellation request submitted.')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel this ride. Please try again.')),
        );
      }
    }
  }
}

class _RouteLine extends StatelessWidget {
  const _RouteLine({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 17, color: color),
      const SizedBox(width: 9),
      Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)),
    ],
  );
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline_rounded, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async => QuickRideAuth.signInWithGoogle(
              redirectTo: 'in.quickride.customer://login-callback',
            ),
            icon: const Icon(Icons.login),
            label: const Text('Continue with Google'),
          ),
        ],
      ),
    ),
  );
}
