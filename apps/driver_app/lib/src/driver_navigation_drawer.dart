import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class DriverNavigationDrawer extends StatelessWidget {
  const DriverNavigationDrawer({super.key});

  Widget _entry(
    BuildContext context,
    IconData icon,
    String label,
    String route,
  ) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () {
          final router = GoRouter.of(context);
          Navigator.of(context).pop();
          router.push(route);
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
                  'Quick Ride Captain',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            _entry(context, Icons.home_outlined, 'Home & availability', '/'),
            _entry(context, Icons.route_outlined, 'My rides', '/section/rides'),
            _entry(context, Icons.account_balance_wallet_outlined, 'Earnings', '/section/earnings'),
            _entry(context, Icons.description_outlined, 'Documents', '/section/documents'),
            const Divider(),
            _entry(context, Icons.person_outline_rounded, 'Profile', '/section/profile'),
            _entry(context, Icons.settings_outlined, 'Settings', '/section/settings'),
            _entry(context, Icons.support_agent_outlined, 'Help & support', '/section/support'),
            _entry(context, Icons.privacy_tip_outlined, 'Privacy policy', '/section/privacy'),
            _entry(context, Icons.info_outline_rounded, 'About Quick Ride', '/section/about'),
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
                          redirectTo: 'in.quickride.driver://login-callback',
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
