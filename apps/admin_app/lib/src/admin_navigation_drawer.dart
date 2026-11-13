import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class AdminNavigationDrawer extends StatelessWidget {
  const AdminNavigationDrawer({super.key});

  Widget _entry(
    BuildContext context,
    IconData icon,
    String label,
    String route,
  ) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () {
          Navigator.of(context).pop();
          context.go(route);
        },
      );

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFF173B2D)),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  'Quick Ride Admin',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            _entry(context, Icons.dashboard_outlined, 'Dashboard', '/'),
            _entry(context, Icons.monitor_heart_outlined, 'Operations', '/operations'),
            _entry(context, Icons.location_city_outlined, 'Service areas & fares', '/service-areas'),
            _entry(context, Icons.notifications_active_outlined, 'Notifications', '/notifications'),
            const Divider(),
            _entry(context, Icons.admin_panel_settings_outlined, 'Admin profile', '/info/profile'),
            _entry(context, Icons.settings_outlined, 'Settings', '/info/settings'),
            _entry(context, Icons.support_agent_outlined, 'Help & support', '/info/support'),
            _entry(context, Icons.privacy_tip_outlined, 'Privacy policy', '/info/privacy'),
            _entry(context, Icons.info_outline_rounded, 'About Quick Ride', '/info/about'),
            const Divider(),
            if (user == null)
              ListTile(
                leading: const Icon(Icons.login_rounded),
                title: const Text('Sign in with Google'),
                enabled: QuickRideBackend.isInitialized,
                onTap: !QuickRideBackend.isInitialized
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        QuickRideAuth.signInWithGoogle(
                          redirectTo: 'in.quickride.admin://login-callback',
                        );
                      },
              )
            else
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Log out'),
                onTap: () {
                  Navigator.of(context).pop();
                  QuickRideAuth.signOut();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class AdminInfoScreen extends StatelessWidget {
  const AdminInfoScreen({super.key, required this.section});
  final String section;

  @override
  Widget build(BuildContext context) {
    final pages = <String, ({String title, String intro, List<String> points})>{
      'profile': (
        title: 'Admin profile',
        intro: 'Administrator access is limited to approved accounts and verified server-side roles.',
        points: [
          'Signed-in account: ${QuickRideAuth.currentUser?.email ?? 'Not signed in'}',
          'Only authorized administrator accounts can perform live management actions.',
          'Read-only exploration does not grant access to customer, driver or financial records.',
        ],
      ),
      'settings': (
        title: 'Settings',
        intro: 'Administrative preferences and platform controls.',
        points: [
          'Platform configuration is managed from the authenticated Operations Centre.',
          'Changes to fares, service areas, driver approvals and dispatch settings are audited.',
          'Sign out when using a shared device.',
        ],
      ),
      'support': (
        title: 'Help & support',
        intro: 'Use the Operations Centre to review support tickets and operational issues.',
        points: [
          'Customer and driver support requests are linked to their ride where available.',
          'Safety events must be reviewed carefully; recording a review does not contact emergency services.',
          'Live support actions require an authorized administrator session.',
        ],
      ),
      'privacy': (
        title: 'Privacy policy',
        intro: 'Quick Ride uses information needed to provide and protect ride services.',
        points: [
          'Account details are used for sign-in, account security and service communication.',
          'Location is used to set pickup points, calculate routes and support active-trip tracking.',
          'Ride details, service selections and transaction records are used for booking, support and operational records.',
          'Driver applicants may submit vehicle and verification documents for review.',
          'Push notification tokens are used to deliver ride and account alerts.',
          'Map services process location and route requests to display maps and calculate directions.',
          'Access to operational records is restricted by authenticated roles and database access policies.',
          'Users can request account deletion through the supported account controls; certain records may be retained where legally or operationally required.',
        ],
      ),
      'about': (
        title: 'About Quick Ride',
        intro: 'Quick Ride is a ride-booking platform connecting customers with independent driver partners.',
        points: [
          'Customer, Driver and Admin apps share the same protected ride and service infrastructure.',
          'Service availability and vehicle categories depend on the configured operating area.',
          'Displayed fares and availability are refreshed from the live booking service.',
        ],
      ),
    };
    final page = pages[section] ?? pages['about']!;
    return Scaffold(
      appBar: AppBar(
        title: Text(page.title),
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(page.intro, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          ...page.points.map((point) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline_rounded, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(point)),
                  ],
                ),
              )),
          if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Preview mode · Live administrative information and actions require an authorized sign-in.'),
            ),
        ],
      ),
    );
  }
}
