import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class DriverSectionScreen extends StatefulWidget {
  const DriverSectionScreen({super.key, required this.section});
  final String section;

  @override
  State<DriverSectionScreen> createState() => _DriverSectionScreenState();
}

class _DriverSectionScreenState extends State<DriverSectionScreen> {
  late Future<dynamic> _data;

  static const _copy = <String, ({String title, String intro, List<String> details})>{
    'rides': (
      title: 'My rides',
      intro: 'Review your recent and active driver trips.',
      details: ['Active trips', 'Completed trips', 'Ride status and fare history'],
    ),
    'earnings': (
      title: 'Earnings',
      intro: 'Review completed-trip earnings and settlement information.',
      details: ['Completed ride earnings', 'Payment and settlement records', 'Recent earnings summary'],
    ),
    'documents': (
      title: 'Documents',
      intro: 'Manage the verification documents required before going online.',
      details: ['Driving licence', 'Vehicle registration certificate', 'Vehicle insurance'],
    ),
    'profile': (
      title: 'Driver profile',
      intro: 'Your driver and vehicle details are used for verification and ride operations.',
      details: ['Driver verification status', 'Registered vehicle details', 'Approved service area'],
    ),
    'settings': (
      title: 'Settings',
      intro: 'Manage the preferences used by Quick Ride Captain.',
      details: ['Notification and sound preferences', 'Location permission and GPS', 'Account security and sign-out'],
    ),
    'support': (
      title: 'Help & support',
      intro: 'Guidance for using Quick Ride Captain.',
      details: ['Keep GPS and notifications enabled while online', 'Use the ride-linked safety controls during an active trip', 'For account or document problems, use the driver support channel provided by Quick Ride operations'],
    ),
    'privacy': (
      title: 'Privacy policy',
      intro: 'Quick Ride processes driver information to provide and protect driver services.',
      details: [
        'Account and vehicle details are used for driver onboarding and identity verification.',
        'Location is shared while online and during active trips to support dispatch, navigation and customer tracking.',
        'Driver documents are stored for verification and reviewed by authorized operations staff.',
        'Ride, fare and settlement records are used for trip history and operational accounting.',
        'Push notification tokens are used for ride offers and account alerts.',
        'Map services process location and route requests to provide maps and directions.',
        'Access to driver records is controlled by authenticated account roles and database policies.',
      ],
    ),
    'about': (
      title: 'About Quick Ride',
      intro: 'Quick Ride Captain helps approved driver partners receive, manage and complete customer trips.',
      details: ['Go online only when you are ready to accept requests.', 'Review pickup and fare details before accepting a trip.', 'Keep your vehicle and verification documents up to date.'],
    ),
  };

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void didUpdateWidget(covariant DriverSectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) _data = _load();
  }

  Future<dynamic> _load() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      return null;
    }
    final user = QuickRideAuth.currentUser!;
    switch (widget.section) {
      case 'rides':
        return QuickRideBackend.client
            .from('rides')
            .select('id,status,estimated_fare,final_fare,created_at')
            .eq('driver_id', user.id)
            .order('created_at', ascending: false)
            .limit(50);
      case 'profile':
        return QuickRideBackend.client
            .from('driver_profiles')
            .select('verification_status,vehicle_make,vehicle_model,vehicle_registration,vehicle_color')
            .eq('user_id', user.id)
            .maybeSingle();
      case 'documents':
        final response = await QuickRideBackend.invoke(
          'driver-ride-actions',
          body: const {'action': 'list_documents'},
        );
        return response.data;
      case 'earnings':
        final response = await QuickRideBackend.invoke(
          'driver-ride-actions',
          body: const {'action': 'get_earnings'},
        );
        return response.data;
      default:
        return null;
    }
  }

  String _money(dynamic value) {
    final number = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    return number == null ? '—' : '₹' + number.toStringAsFixed(2);
  }

  Widget _liveContent(dynamic value) {
    switch (widget.section) {
      case 'rides':
        final rows = value is List ? value : const [];
        if (rows.isEmpty) return const Text('No rides found for this account yet.');
        return Column(
          children: rows.map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = row['id'].toString();
            return Card(
              child: ListTile(
                leading: const Icon(Icons.route_outlined),
                title: Text('Ride ' + id.substring(0, id.length < 8 ? id.length : 8)),
                subtitle: Text(row['status'].toString().replaceAll('_', ' ')),
                trailing: Text(_money(row['final_fare'] ?? row['estimated_fare'])),
              ),
            );
          }).toList(),
        );
      case 'profile':
        if (value is! Map) return const Text('Driver profile has not been created yet.');
        final row = Map<String, dynamic>.from(value);
        return Card(
          child: Column(
            children: [
              ListTile(title: const Text('Verification'), subtitle: Text((row['verification_status'] ?? 'pending').toString())),
              ListTile(title: const Text('Vehicle'), subtitle: Text([row['vehicle_make'], row['vehicle_model']].where((v) => v != null).join(' '))),
              ListTile(title: const Text('Registration'), subtitle: Text((row['vehicle_registration'] ?? 'Not provided').toString())),
              ListTile(title: const Text('Colour'), subtitle: Text((row['vehicle_color'] ?? 'Not provided').toString())),
            ],
          ),
        );
      case 'documents':
        final data = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
        final docs = data['documents'] as List<dynamic>? ?? [];
        if (docs.isEmpty) return const Text('No driver documents have been uploaded yet.');
        return Column(
          children: docs.map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            return Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(row['document_type'].toString().replaceAll('_', ' ')),
                subtitle: Text((row['verification_status'] ?? 'pending').toString().replaceAll('_', ' ')),
              ),
            );
          }).toList(),
        );
      case 'earnings':
        final data = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
        final totals = data['totals'] as Map<String, dynamic>? ?? {};
        final inr = totals['INR'] as Map<String, dynamic>? ?? {};
        return Card(
          child: Column(
            children: [
              ListTile(title: const Text('Completed rides'), trailing: Text((data['completed_ride_count'] ?? 0).toString())),
              ListTile(title: const Text('Total earnings'), trailing: Text(_money(inr['total'] ?? inr['earned']))),
              ListTile(title: const Text('Recent rides'), trailing: Text((data['recent_window_ride_count'] ?? 0).toString())),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _copy[widget.section] ?? _copy['about']!;
    final signedIn = QuickRideBackend.isInitialized && QuickRideAuth.currentUser != null;
    final needsData = const {'rides', 'earnings', 'documents', 'profile'}.contains(widget.section);
    return Scaffold(
      appBar: AppBar(
        title: Text(page.title),
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(page.intro, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          if (needsData && signedIn)
            FutureBuilder<dynamic>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  ));
                }
                if (snapshot.hasError) {
                  return const Text('This information is temporarily unavailable. Please try again.');
                }
                return _liveContent(snapshot.data);
              },
            )
          else if (needsData)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Preview mode · Sign in to view your private ' + page.title.toLowerCase() + ' information.'),
              ),
            ),
          if (widget.section == 'settings' || widget.section == 'support' || widget.section == 'privacy' || widget.section == 'about' || !needsData) ...[
            ...page.details.map((detail) => Padding(
                  padding: const EdgeInsets.only(bottom: 13),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 19),
                      const SizedBox(width: 10),
                      Expanded(child: Text(detail)),
                    ],
                  ),
                )),
          ],
          if (!signedIn)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.icon(
                onPressed: QuickRideBackend.isInitialized
                    ? () => QuickRideAuth.signInWithGoogle(
                          redirectTo: 'in.quickride.driver://login-callback',
                        )
                    : null,
                icon: const Icon(Icons.login_rounded),
                label: const Text('Sign in with Google'),
              ),
            ),
        ],
      ),
    );
  }
}
