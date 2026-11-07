import 'package:flutter/material.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});
  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final pin = TextEditingController();
  Future<List<Map<String, dynamic>>>? areas;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) areas = loadAreas();
  }

  Future<List<Map<String, dynamic>>> loadAreas() async {
    final rows = await QuickRideBackend.client
        .from('service_area_pincodes')
        .select('pincode,label,service_areas!inner(city,state)')
        .eq('is_active', true)
        .order('pincode');
    return rows;
  }

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick-Ride'),
        actions: [
          if (user == null)
            TextButton(
              onPressed: QuickRideBackend.isInitialized
                  ? () => QuickRideAuth.signInWithGoogle(
                        redirectTo: 'in.quickride.customer://login-callback',
                      )
                  : null,
              child: const Text('Sign in'),
            )
          else
            IconButton(onPressed: QuickRideAuth.signOut, icon: const Icon(Icons.logout)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Your ride, on your time',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          const Text('Explore service availability before signing in. Booking requires an account.'),
          const SizedBox(height: 20),
          TextField(
            controller: pin,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'Pickup pincode',
              prefixIcon: Icon(Icons.location_on_outlined),
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (!QuickRideBackend.isInitialized)
            const Text('Connect Supabase using build-time configuration to load active service areas.')
          else
            FutureBuilder<List<Map<String, dynamic>>>(
              future: areas,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  if (snapshot.hasError) return Text('Service lookup failed: ' + snapshot.error.toString());
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snapshot.data!.where((item) =>
                    pin.text.isEmpty || item['pincode'].toString().startsWith(pin.text)).toList();
                if (rows.isEmpty) return const Text('No active service area matches this pincode.');
                return Column(
                  children: rows.map((item) {
                    final area = item['service_areas'] as Map<String, dynamic>;
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.route),
                        title: Text(item['pincode'].toString()),
                        subtitle: Text(area['city'].toString() + ', ' + area['state'].toString()),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          const SizedBox(height: 20),
          const ListTile(
            leading: Icon(Icons.map_outlined),
            title: Text('Live pickup and driver tracking'),
            subtitle: Text('Available after service-area boundaries and Mapbox credentials are configured.'),
          ),
        ],
      ),
    );
  }
}
