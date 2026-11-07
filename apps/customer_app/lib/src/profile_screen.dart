import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

import 'customer_navigation_bar.dart';

class CustomerProfileScreen extends StatefulWidget {
  const CustomerProfileScreen({super.key});

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
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
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: colors.primary,
                  child: Icon(Icons.person_rounded, size: 34, color: colors.onPrimary),
                ),
                const SizedBox(height: 12),
                Text(
                  user?.email ?? 'Guest account',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 5),
                Text(
                  user == null ? 'Explore Quick-Ride without signing in.' : 'Signed in with your Google account.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                if (user == null) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: QuickRideBackend.isInitialized
                        ? () async => QuickRideAuth.signInWithGoogle(
                              redirectTo: 'in.quickride.customer://login-callback',
                            )
                        : null,
                    icon: const Icon(Icons.login),
                    label: const Text('Continue with Google'),
                  ),
                ] else ...[
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await QuickRideAuth.signOut();
                      if (context.mounted) context.go('/');
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.route_outlined),
                  title: const Text('My Rides'),
                  subtitle: const Text('View your current and previous rides'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/my-rides'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Help & Support'),
                  subtitle: const Text('Get help with a ride or a general issue'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/support'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Account security',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            'Booking and ride details are available after Google sign-in. Driver and administrator access are granted separately and cannot be enabled from this screen.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 3),
    );
  }
}
