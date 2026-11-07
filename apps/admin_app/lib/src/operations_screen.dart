import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
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
  bool _busy = false;
  String? _error;
  StreamSubscription<dynamic>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      if (QuickRideAuth.currentUser != null) unawaited(_refresh());
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (!mounted) return;
        if (QuickRideAuth.currentUser != null) {
          setState(() {});
          if (_summary == null && !_busy) unawaited(_refresh());
        } else {
          setState(() {
            _summary = null;
            _drivers = [];
            _pincodeRequests = [];
          });
        }
      });
    }
  }

  @override
  void dispose() {
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

  Future<void> _refresh() async {
    setState(() { _busy = true; _error = null; });
    try {
      final results = await Future.wait([
        _call('dashboard_summary'),
        _call('list_driver_applications'),
        _call('list_driver_pincode_requests', {'status': 'pending'}),
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

  @override
  Widget build(BuildContext context) {
    if (!QuickRideBackend.isInitialized) {
      return const Scaffold(
        body: Center(child: Text('Quick-Ride backend is not configured.')),
      );
    }
    if (QuickRideAuth.currentUser == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Operations')),
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
    final summary = _summary ?? const <String, dynamic>{};
    final commission = summary['commission_totals'] as Map<String, dynamic>? ?? {};
    return Scaffold(
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
          ],
        ),
      ),
    );
  }
}
