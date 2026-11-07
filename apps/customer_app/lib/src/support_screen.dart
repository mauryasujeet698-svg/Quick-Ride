import 'package:flutter/material.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

import 'customer_navigation_bar.dart';

class CustomerSupportScreen extends StatefulWidget {
  const CustomerSupportScreen({super.key, this.initialRideId});

  final String? initialRideId;

  @override
  State<CustomerSupportScreen> createState() => _CustomerSupportScreenState();
}

class _CustomerSupportScreenState extends State<CustomerSupportScreen> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  String? _selectedRideId;
  String _category = 'ride';
  List<Map<String, dynamic>> _rides = [];
  bool _loadingRides = false;
  bool _submitting = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _selectedRideId = widget.initialRideId;
    _loadRides();
  }

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _loadRides() async {
    final user = QuickRideAuth.currentUser;
    if (user == null || !QuickRideBackend.isInitialized) return;
    setState(() => _loadingRides = true);
    try {
      final rows = await QuickRideBackend.client
          .from('rides')
          .select('id,status,created_at,pickup_address,destination_address')
          .eq('customer_id', user.id)
          .order('created_at', ascending: false)
          .limit(30);
      if (!mounted) return;
      setState(() => _rides = rows);
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not load your rides: ' + error.toString());
    } finally {
      if (mounted) setState(() => _loadingRides = false);
    }
  }

  Future<void> _submit() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      setState(() => _message = 'Sign in with Google before submitting a support request.');
      return;
    }
    if (_subject.text.trim().isEmpty || _description.text.trim().isEmpty) {
      setState(() => _message = 'Enter a subject and describe the issue.');
      return;
    }
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await QuickRideBackend.client.from('ride_support_tickets').insert({
        'submitted_by': user.id,
        'ride_id': _selectedRideId,
        'category': _category,
        'subject': _subject.text.trim(),
        'description': _description.text.trim(),
        'priority': _category == 'safety' ? 'urgent' : 'normal',
      });
      if (!mounted) return;
      setState(() {
        _subject.clear();
        _description.clear();
        _message = 'Your support request has been submitted.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Support request failed: ' + error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (!QuickRideBackend.isInitialized) {
      return const Scaffold(body: Center(child: Text('Quick-Ride backend is not configured.')));
    }
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Help & Support')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.support_agent_rounded, size: 48),
                const SizedBox(height: 12),
                const Text('Sign in to select a ride and contact Quick-Ride support.', textAlign: TextAlign.center),
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
        ),
        bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 2),
      );
    }

    final validSelection = _rides.any((ride) => ride['id'].toString() == _selectedRideId);
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('What do you need help with?', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 7),
          Text('Select the ride related to your issue. You can also contact us about a general question.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
          DropdownButtonFormField<String?>(
            initialValue: validSelection ? _selectedRideId : null,
            decoration: const InputDecoration(
              labelText: 'Select a ride',
              prefixIcon: Icon(Icons.route_outlined),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('General support — no ride selected')),
              ..._rides.map((ride) {
                final id = ride['id'].toString();
                final label = 'Ride ' + id.substring(0, id.length < 8 ? id.length : 8) +
                    ' · ' + ride['status'].toString().replaceAll('_', ' ');
                return DropdownMenuItem<String?>(value: id, child: Text(label, overflow: TextOverflow.ellipsis));
              }),
            ],
            onChanged: _loadingRides ? null : (value) => setState(() => _selectedRideId = value),
          ),
          if (_loadingRides) const LinearProgressIndicator(),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Issue category'),
            items: const [
              DropdownMenuItem(value: 'ride', child: Text('Ride experience')),
              DropdownMenuItem(value: 'payment', child: Text('Payment or fare')),
              DropdownMenuItem(value: 'driver', child: Text('Driver concern')),
              DropdownMenuItem(value: 'safety', child: Text('Safety concern')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: _submitting ? null : (value) => setState(() => _category = value ?? 'ride'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _subject,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Subject'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _description,
            minLines: 4,
            maxLines: 7,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Describe your issue',
              alignLabelWithHint: true,
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(color: _message!.startsWith('Your ') ? Colors.green : Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: const Text('Submit support request'),
          ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 2),
    );
  }
}
