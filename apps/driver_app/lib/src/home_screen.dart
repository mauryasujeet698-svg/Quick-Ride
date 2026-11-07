import 'package:flutter/material.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});
  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final pin = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> invoke(String action, Map<String, dynamic> values) async {
    if (!QuickRideBackend.isInitialized) return;
    setState(() => busy = true);
    try {
      final result = await QuickRideBackend.invoke(
        'driver-ride-actions',
        body: {'action': action, ...values},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.data.toString())),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request failed: ' + error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick-Ride Driver')),
        body: Center(
          child: FilledButton(
            onPressed: QuickRideBackend.isInitialized
                ? () => QuickRideAuth.signInWithGoogle(
                      redirectTo: 'in.quickride.driver://login-callback',
                    )
                : null,
            child: const Text('Sign in with Google'),
          ),
        ),
      );
    }
    final offerStream = QuickRideBackend.client
        .from('ride_offers').stream(primaryKey: ['id'])
        .eq('driver_id', user.id).eq('status', 'pending');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver console'),
        actions: [IconButton(onPressed: QuickRideAuth.signOut, icon: const Icon(Icons.logout))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Service availability', style: Theme.of(context).textTheme.titleLarge),
          TextField(
            controller: pin,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Approved service pincode', counterText: ''),
          ),
          Wrap(spacing: 8, children: [
            FilledButton(
              onPressed: busy ? null : () => invoke('set_online', {'pincode': pin.text.trim()}),
              child: const Text('Go online'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => invoke('set_offline', const {}),
              child: const Text('Go offline'),
            ),
          ]),
          const SizedBox(height: 24),
          Text('Incoming offers', style: Theme.of(context).textTheme.titleLarge),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: offerStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('Offer stream error: ' + snapshot.error.toString());
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              if (snapshot.data!.isEmpty) return const Text('No active offers.');
              return Column(
                children: snapshot.data!.map((offer) => Card(
                  child: ListTile(
                    title: const Text('New ride request'),
                    subtitle: Text('Expires: ' + offer['expires_at'].toString()),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) => invoke(action, {'offerId': offer['id'].toString()}),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'accept_offer', child: Text('Accept')),
                        PopupMenuItem(value: 'reject_offer', child: Text('Reject')),
                      ],
                    ),
                  ),
                )).toList(),
              );
            },
          ),
          const SizedBox(height: 12),
          const Text('A preaccepted next ride will only be assigned after your active trip completes.'),
        ],
      ),
    );
  }
}
