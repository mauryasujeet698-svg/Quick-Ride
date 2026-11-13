import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'admin_navigation_drawer.dart';
import 'package:url_launcher/url_launcher.dart';

class AdminOperationsScreen extends StatefulWidget {
  const AdminOperationsScreen({super.key});
  @override
  State<AdminOperationsScreen> createState() => _AdminOperationsScreenState();
}

class _AdminOperationsScreenState extends State<AdminOperationsScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _pincodeRequests = [];
  List<Map<String, dynamic>> _supportTickets = [];
  List<Map<String, dynamic>> _safetyEvents = [];
  bool _busy = false;
  String? _error;
  StreamSubscription<dynamic>? _authSubscription;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      if (QuickRideAuth.currentUser != null) {
        unawaited(_refresh());
        _startRefreshTimer();
      }
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (!mounted) return;
        if (QuickRideAuth.currentUser != null) {
          setState(() {});
          _startRefreshTimer();
          if (_summary == null && !_busy) unawaited(_refresh());
        } else {
          _refreshTimer?.cancel();
          _refreshTimer = null;
          setState(() {
            _summary = null;
            _drivers = [];
            _pincodeRequests = [];
            _supportTickets = [];
            _safetyEvents = [];
          });
        }
      });
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    if (QuickRideAuth.currentUser == null) return;
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_busy) unawaited(_refreshSafetyEvents());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String action, [Map<String, dynamic> body = const {}]) async {
    final response = await QuickRideBackend.invoke(
      'admin-service-areas',
      body: {'action': action, ...body},
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> _refreshSafetyEvents() async {
    if (!mounted || _busy || QuickRideAuth.currentUser == null) return;
    try {
      final result = await _call('list_safety_events');
      if (!mounted) return;
      setState(() {
        _safetyEvents = (result['safety_events'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      final results = await Future.wait([
        _call('dashboard_summary'),
        _call('list_driver_applications'),
        _call('list_driver_pincode_requests', {'status': 'pending'}),
        _call('list_support_tickets', {'status': 'active'}),
        _call('list_safety_events'),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0];
        _drivers = (results[1]['applications'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .where((item) => item['verification_status'] == 'pending')
            .toList();
        _pincodeRequests = (results[2]['requests'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _supportTickets = (results[3]['tickets'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _safetyEvents = (results[4]['safety_events'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewDriver(String id, String decision) async {
    setState(() => _busy = true);
    try {
      await _call('review_driver_application', {'driverId': id, 'decision': decision});
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewPincode(String id, String decision) async {
    setState(() => _busy = true);
    try {
      await _call('review_driver_pincode', {'requestId': id, 'decision': decision});
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewDocument(String id, String decision) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _call('review_driver_document', {
        'documentId': id,
        'decision': decision,
      });
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateSupportTicket(String id, String status) async {
    setState(() { _busy = true; _error = null; });
    try {
      await _call('update_support_ticket', {
        'ticketId': id,
        'status': status,
      });
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolveSafetyEvent(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark safety event reviewed?'),
        content: const Text(
          'This records an Operations review entry. It does not mean that '
          'emergency services have been contacted or that the incident is resolved externally.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Record review'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _call('resolve_safety_event', {'eventId': id});
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDocument(String? url) async {
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _error = 'A document preview link is not available.');
      return;
    }
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      setState(() => _error = 'The document preview could not be opened.');
    }
  }

  Widget _metric(String label, Object? value, IconData icon) => Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(value?.toString() ?? '—', style: Theme.of(context).textTheme.headlineSmall),
          subtitle: Text(label),
        ),
      );

  Widget _previewMetric(String label, IconData icon) => Card(
        child: ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text('—', style: Theme.of(context).textTheme.titleLarge),
          subtitle: Text(label),
        ),
      );

  Widget _previewScreen() => Scaffold(
        drawer: const AdminNavigationDrawer(),
        appBar: AppBar(
          title: const Text('Operations preview'),
          leading: IconButton(
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              'Platform pulse',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This is the read-only layout preview. Live platform figures '
              'appear after an administrator signs in and Supabase is configured.',
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.65,
              children: [
                _previewMetric('Total rides', Icons.route_outlined),
                _previewMetric('Active rides', Icons.directions_car_outlined),
                _previewMetric('Completed rides', Icons.check_circle_outline),
                _previewMetric('Registered drivers', Icons.people_outline),
                _previewMetric('Pending driver reviews', Icons.fact_check_outlined),
                _previewMetric('Active pincodes', Icons.location_on_outlined),
              ],
            ),
            const SizedBox(height: 14),
            Text('Operational queues',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.verified_user_outlined),
                title: Text('Driver approvals'),
                subtitle: Text('KYC and profile review queue'),
                trailing: Text('Preview'),
              ),
            ),
            const Card(
              child: ListTile(
                leading: Icon(Icons.location_on_outlined),
                title: Text('Pincode applications'),
                subtitle: Text('Pending service-area requests'),
                trailing: Text('Preview'),
              ),
            ),
            const Card(
              child: ListTile(
                leading: Icon(Icons.support_agent_outlined),
                title: Text('Support tickets'),
                subtitle: Text('Customer and driver support queue'),
                trailing: Text('Preview'),
              ),
            ),
            const Card(
              child: ListTile(
                leading: Icon(Icons.sos_outlined),
                title: Text('Safety events'),
                subtitle: Text('SOS and safety review queue'),
                trailing: Text('Preview'),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!QuickRideBackend.isInitialized ||
        QuickRideAuth.currentUser == null) {
      return _previewScreen();
    }
    final summary = _summary ?? const <String, dynamic>{};
    final commission = summary['commission_totals'] as Map<String, dynamic>? ?? {};
    return Scaffold(
      drawer: const AdminNavigationDrawer(),
      appBar: AppBar(
        title: const Text('Operations'),
        leading: IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back)),
        actions: [IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Platform pulse', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              children: [
                _metric('Total rides', summary['rides_total'], Icons.route),
                _metric('Active rides', summary['rides_active'], Icons.directions_car),
                _metric('Completed rides', summary['rides_completed'], Icons.check_circle_outline),
                _metric('Registered drivers', summary['drivers_total'], Icons.people_outline),
                _metric('Pending driver reviews', summary['drivers_pending_review'], Icons.fact_check_outlined),
                _metric('Active pincodes', summary['pincodes_active'], Icons.location_on_outlined),
              ],
            ),
            if (commission.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Recorded platform commission', style: Theme.of(context).textTheme.titleMedium),
              ...commission.entries.map((entry) => ListTile(
                    title: Text(entry.key),
                    trailing: Text((entry.value as num).toStringAsFixed(2)),
                  )),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            Text('Driver applications', style: Theme.of(context).textTheme.titleLarge),
            if (_drivers.isEmpty)
              const ListTile(title: Text('No pending driver applications.'))
            else
              ..._drivers.map((driver) {
                final docs = driver['driver_documents'] as List<dynamic>? ?? [];
                final pinRequests = driver['driver_service_pincodes'] as List<dynamic>? ?? [];
                final id = driver['user_id'].toString();
                final shortId = id.substring(0, id.length < 8 ? id.length : 8);
                final vehicle = (driver['vehicle_make'] ?? '').toString() + ' ' +
                    (driver['vehicle_model'] ?? '').toString() + ' · ' +
                    (driver['vehicle_registration'] ?? '').toString();
                return Card(
                  child: ExpansionTile(
                    title: Text('Driver ' + shortId),
                    subtitle: Text(vehicle),
                    children: [
                      if (docs.isEmpty)
                        const ListTile(
                          dense: true,
                          leading: Icon(Icons.warning_amber_rounded),
                          title: Text('No verification documents uploaded yet.'),
                        ),
                      ...docs.map((document) {
                        final doc = Map<String, dynamic>.from(document as Map);
                        final documentId = doc['id'].toString();
                        final status = doc['verification_status'].toString();
                        final signedUrl = doc['signed_url']?.toString();
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      doc['document_type'].toString().replaceAll('_', ' '),
                                      style: const TextStyle(fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  Chip(label: Text(status.replaceAll('_', ' '))),
                                ],
                              ),
                              if (doc['expires_at'] != null)
                                Text('Expires: ' + doc['expires_at'].toString()),
                              if (doc['review_note'] != null && doc['review_note'].toString().isNotEmpty)
                                Text('Review note: ' + doc['review_note'].toString()),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: signedUrl == null ? null : () => _openDocument(signedUrl),
                                    icon: const Icon(Icons.open_in_new, size: 18),
                                    label: const Text('View document'),
                                  ),
                                  if (status == 'pending' || status == 'under_review') ...[
                                    OutlinedButton(
                                      onPressed: _busy ? null : () => _reviewDocument(documentId, 'rejected'),
                                      child: const Text('Reject document'),
                                    ),
                                    FilledButton.tonal(
                                      onPressed: _busy ? null : () => _reviewDocument(documentId, 'approved'),
                                      child: const Text('Approve document'),
                                    ),
                                  ],
                                ],
                              ),
                              const Divider(height: 12),
                            ],
                          ),
                        );
                      }),
                      ...pinRequests.map((request) {
                        final req = Map<String, dynamic>.from(request as Map);
                        final pin = req['service_area_pincodes'] as Map<String, dynamic>? ?? {};
                        return ListTile(
                          dense: true,
                          title: Text('Pincode ' + (pin['pincode']?.toString() ?? req['pincode_id'].toString())),
                          subtitle: Text('Service area request: ' + req['status'].toString()),
                        );
                      }),
                      Builder(
                        builder: (context) {
                          const requiredTypes = ['driving_license', 'vehicle_rc', 'insurance'];
                          final approvedTypes = docs
                              .map((document) => Map<String, dynamic>.from(document as Map))
                              .where((document) => document['verification_status'] == 'approved' &&
                                  (document['expires_at'] == null ||
                                      DateTime.tryParse(document['expires_at'].toString())?.isAfter(DateTime.now()) == true))
                              .map((document) => document['document_type'].toString())
                              .toSet();
                          final readyForApproval = requiredTypes.every(approvedTypes.contains);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!readyForApproval)
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 16),
                                  child: Text('Approve the driving licence, vehicle RC and insurance before approving this driver.'),
                                ),
                              OverflowBar(
                                children: [
                                  TextButton(
                                    onPressed: _busy ? null : () => _reviewDriver(id, 'rejected'),
                                    child: const Text('Reject application'),
                                  ),
                                  FilledButton(
                                    onPressed: _busy || !readyForApproval ? null : () => _reviewDriver(id, 'approved'),
                                    child: const Text('Approve driver'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                );
              }),
            const SizedBox(height: 24),
            Text('Pending service-pincode approvals', style: Theme.of(context).textTheme.titleLarge),
            if (_pincodeRequests.isEmpty)
              const ListTile(title: Text('No pending pincode requests.'))
            else
              ..._pincodeRequests.map((request) {
                final pin = request['service_area_pincodes'] as Map<String, dynamic>? ?? {};
                final id = request['id'].toString();
                final driverId = request['driver_id'].toString();
                final shortId = driverId.substring(0, driverId.length < 8 ? driverId.length : 8);
                return Card(
                  child: ListTile(
                    title: Text('Pincode ' + (pin['pincode']?.toString() ?? request['pincode_id'].toString())),
                    subtitle: Text('Driver ' + shortId),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          onPressed: _busy ? null : () => _reviewPincode(id, 'rejected'),
                          icon: const Icon(Icons.close),
                        ),
                        IconButton(
                          onPressed: _busy ? null : () => _reviewPincode(id, 'active'),
                          icon: const Icon(Icons.check),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 24),
            Text('Ride safety alerts', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            const Text(
              'SOS and incident reports are shown here while Operations is open. '
              'This is not a 24/7 emergency dispatch or public-safety notification service.',
            ),
            if (_safetyEvents.isEmpty)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('No unreviewed safety alerts.'),
              )
            else
              ..._safetyEvents.map((event) {
                final id = event['id'].toString();
                final ride = event['rides'] as Map<String, dynamic>?;
                final created = DateTime.tryParse(event['created_at'].toString());
                final rideId = event['ride_id'].toString();
                final shortRideId = rideId.substring(0, rideId.length < 8 ? rideId.length : 8);
                return Card(
                  child: ExpansionTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      event['event_type'].toString().replaceAll('_', ' ').toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      'Ride $shortRideId · ' +
                      (created?.toLocal().toString().substring(0, 16) ?? 'Time unavailable'),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Reported by: ' + (event['actor_name']?.toString() ?? 'Quick-Ride user')),
                            if (ride != null) ...[
                              Text('Ride status: ' + (ride['status']?.toString() ?? 'unknown').replaceAll('_', ' ')),
                              Text('Pickup: ' + (ride['pickup_address']?.toString() ?? '—')),
                              Text('Destination: ' + (ride['destination_address']?.toString() ?? '—')),
                            ],
                            const SizedBox(height: 8),
                            const Text('Review the incident and follow your operational emergency procedure.'),
                            const SizedBox(height: 10),
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : () => _resolveSafetyEvent(id),
                              icon: const Icon(Icons.fact_check_outlined),
                              label: const Text('Record Operations review'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            const SizedBox(height: 24),
            Text('Customer support tickets', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Review ride-related and general customer requests. Update the ticket status as your team handles it.'),
            if (_supportTickets.isEmpty)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('No open support tickets.'),
              )
            else
              ..._supportTickets.map((ticket) {
                final id = ticket['id'].toString();
                final ride = ticket['rides'] as Map<String, dynamic>?;
                final priority = ticket['priority'].toString();
                final status = ticket['status'].toString();
                final customer = ticket['customer_name']?.toString() ?? 'Quick-Ride customer';
                final category = ticket['category'].toString().replaceAll('_', ' ');
                return Card(
                  child: ExpansionTile(
                    leading: Icon(
                      priority == 'urgent' || category == 'safety'
                          ? Icons.priority_high_rounded
                          : Icons.support_agent_outlined,
                      color: priority == 'urgent' || category == 'safety'
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    title: Text(ticket['subject'].toString()),
                    subtitle: Text('$customer · $category · $priority'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Chip(label: Text(status.replaceAll('_', ' '))),
                            ),
                            Text(ticket['description'].toString()),
                            if (ride != null) ...[
                              const SizedBox(height: 8),
                              Text('Ride status: ' + (ride['status']?.toString() ?? 'unknown').replaceAll('_', ' ')),
                              Text('Pickup: ' + (ride['pickup_address']?.toString() ?? '—')),
                              Text('Destination: ' + (ride['destination_address']?.toString() ?? '—')),
                            ] else
                              const Text('General support request (not linked to a ride).'),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              initialValue: status,
                              decoration: const InputDecoration(labelText: 'Update ticket status'),
                              items: const [
                                DropdownMenuItem(value: 'open', child: Text('Open')),
                                DropdownMenuItem(value: 'in_progress', child: Text('In progress')),
                                DropdownMenuItem(value: 'waiting_for_customer', child: Text('Waiting for customer')),
                                DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
                                DropdownMenuItem(value: 'closed', child: Text('Closed')),
                              ],
                              onChanged: _busy ? null : (value) {
                                if (value != null && value != status) {
                                  _updateSupportTicket(id, value);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
