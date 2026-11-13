import 'package:flutter/material.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'admin_navigation_drawer.dart';

class AdminNotificationCenterScreen extends StatefulWidget {
  const AdminNotificationCenterScreen({super.key});

  @override
  State<AdminNotificationCenterScreen> createState() =>
      _AdminNotificationCenterScreenState();
}

class _AdminNotificationCenterScreenState
    extends State<AdminNotificationCenterScreen> {
  final _title = TextEditingController(text: 'Quick Ride test notification');
  final _body = TextEditingController(
    text: 'This is a test notification from the Quick Ride Admin app.',
  );
  final _userIds = TextEditingController();
  String _appRole = 'customer';
  String _recipientMode = 'self';
  bool _sending = false;
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _userIds.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      setState(() => _error = 'Sign in with an authorized Admin account first.');
      return;
    }
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      setState(() => _error = 'Enter both a notification title and message.');
      return;
    }
    List<String> userIds = const [];
    if (_recipientMode == 'selected') {
      userIds = _userIds.text
          .split(RegExp(r'[\s,;]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (userIds.isEmpty) {
        setState(() => _error = 'Enter one or more recipient user UUIDs.');
        return;
      }
    }
    if (_recipientMode == 'app_users') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Send to registered devices?'),
          content: const Text(
            'This sends to up to 100 distinct users with registered devices in the selected application audience. It does not target every user beyond that limit.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Send notification'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() {
      _sending = true;
      _error = null;
      _result = null;
    });
    try {
      final response = await QuickRideBackend.invoke(
        'admin-service-areas',
        body: {
          'action': 'send_notification',
          'appRole': _appRole,
          'recipientMode': _recipientMode,
          'userIds': userIds,
          'title': _title.text.trim(),
          'body': _body.text.trim(),
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() => _result = data);
    } catch (error) {
      if (mounted) setState(() => _error = 'Notification could not be sent. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasAdminSession =
        QuickRideBackend.isInitialized && QuickRideAuth.currentUser != null;
    return Scaffold(
      drawer: const AdminNavigationDrawer(),
      appBar: AppBar(title: const Text('Notification centre')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.notifications_active_outlined,
                          color: colors.primary),
                      const SizedBox(width: 10),
                      Text('Send push notification',
                          style: Theme.of(context).textTheme.titleLarge),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Send a test, targeted message or a limited broadcast through the protected Supabase notification service.',
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: _appRole,
                    decoration:
                        const InputDecoration(labelText: 'Application audience'),
                    items: const [
                      DropdownMenuItem(
                          value: 'customer', child: Text('Quick Ride · Customer')),
                      DropdownMenuItem(
                          value: 'driver', child: Text('Quick Ride Captain · Driver')),
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                      DropdownMenuItem(value: 'all', child: Text('All three applications')),
                    ],
                    onChanged: _sending
                        ? null
                        : (value) => setState(() => _appRole = value ?? 'customer'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _recipientMode,
                    decoration: const InputDecoration(labelText: 'Recipients'),
                    items: const [
                      DropdownMenuItem(
                          value: 'self', child: Text('My test devices')),
                      DropdownMenuItem(
                          value: 'selected', child: Text('Selected user UUIDs')),
                      DropdownMenuItem(
                          value: 'app_users',
                          child: Text('Registered users in selected app (max 100)')),
                    ],
                    onChanged: _sending
                        ? null
                        : (value) => setState(
                            () => _recipientMode = value ?? 'self'),
                  ),
                  if (_recipientMode == 'self') ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Sends to devices registered to the currently signed-in Admin account, filtered by the application audience above.',
                    ),
                  ],
                  if (_recipientMode == 'selected') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _userIds,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Recipient user UUIDs',
                        hintText: 'Paste one or more UUIDs, separated by commas or new lines',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: _title,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Notification title',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _body,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 250,
                    decoration: const InputDecoration(
                      labelText: 'Notification message',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(color: colors.error)),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _sending || !hasAdminSession ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                      label: Text(_sending ? 'Sending…' : 'Send notification'),
                    ),
                  ),
                  if (!hasAdminSession) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Sign in with an active Admin or Operations account to use this tool.',
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Delivery result',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('Attempted: ${_result!['attempted'] ?? 0}'),
                    Text('Sent: ${_result!['sent'] ?? 0}'),
                    Text('Users targeted: ${_result!['recipient_users'] ?? 0}'),
                    if (_result!['truncated'] == true)
                      const Text(
                        'Audience was capped at 100 users. Narrow the audience or send another batch.',
                      ),
                    if (_result!['stale_tokens_removed'] != null)
                      Text('Stale registrations removed: ${_result!['stale_tokens_removed']}'),
                    if (_result!['message'] is String)
                      Text(_result!['message'].toString()),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
