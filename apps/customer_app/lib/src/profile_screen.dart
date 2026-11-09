import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';

import '../customer_preferences.dart';
import 'customer_navigation_bar.dart';

class CustomerProfileScreen extends StatefulWidget {
  const CustomerProfileScreen({super.key});

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  StreamSubscription<dynamic>? _authSubscription;
  bool _deleting = false;

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

  String _t(String english, String hindi) =>
      QuickRideCustomerPreferences.locale.value.languageCode == 'hi'
          ? hindi
          : english;

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Delete your account?', 'अपना खाता हटाएं?')),
        content: Text(_t(
          'This disables future sign-in and removes your profile details. Ride, payment, safety or legally required records may need to remain in an anonymized form. This action cannot be undone.',
          'इससे आगे साइन-इन बंद हो जाएगा और आपकी प्रोफ़ाइल जानकारी हटाई जाएगी। आवश्यक राइड, भुगतान, सुरक्षा या कानूनी रिकॉर्ड अनाम रूप में सुरक्षित रखे जा सकते हैं। यह कार्रवाई वापस नहीं ली जा सकती।',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('Delete account', 'खाता हटाएं')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await QuickRideNotifications.unregisterCurrentDevice();
      final resultResponse = await QuickRideBackend.invoke(
        'delete-account',
        body: const {},
      );
      final result = Map<String, dynamic>.from(resultResponse.data as Map);
      await QuickRideAuth.signOut();
      if (!mounted) return;
      final retained = result['mode'] == 'anonymized_retained_records';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(retained
              ? _t(
                  'Your account is disabled and profile details were removed. Some required records were retained.',
                  'आपका खाता बंद कर दिया गया है और प्रोफ़ाइल जानकारी हटाई गई है। कुछ आवश्यक रिकॉर्ड सुरक्षित रखे गए हैं।',
                )
              : _t('Your account has been deleted.', 'आपका खाता हटा दिया गया है।')),
        ),
      );
      context.go('/');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Account deletion failed: $error', 'खाता हटाने में विफल: $error'))),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    final colors = Theme.of(context).colorScheme;
    final isHindi = QuickRideCustomerPreferences.locale.value.languageCode == 'hi';
    return Scaffold(
      appBar: AppBar(title: Text(_t('Profile & settings', 'प्रोफ़ाइल और सेटिंग्स'))),
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
                  user?.email ?? _t('Guest account', 'अतिथि खाता'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 5),
                Text(
                  user == null
                      ? _t('Explore Quick Ride without signing in.', 'बिना साइन-इन के Quick Ride देखें।')
                      : _t('Signed in with your Google account.', 'आप Google खाते से साइन इन हैं।'),
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
                    label: Text(_t('Continue with Google', 'Google से जारी रखें')),
                  ),
                ] else ...[
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await QuickRideNotifications.unregisterCurrentDevice();
                      await QuickRideAuth.signOut();
                      if (context.mounted) context.go('/');
                    },
                    icon: const Icon(Icons.logout),
                    label: Text(_t('Sign out', 'साइन आउट')),
                  ),
                ],
              ],
            ),
          ),
          _heading(context, _t('Your account', 'आपका खाता')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.route_outlined),
                  title: Text(_t('My rides', 'मेरी राइड')),
                  subtitle: Text(_t('Current, completed and cancelled rides', 'वर्तमान, पूरी और रद्द राइड')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/my-rides'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: Text(_t('Help & support', 'सहायता और सपोर्ट')),
                  subtitle: Text(_t('Get help with a ride or a general issue', 'राइड या अन्य समस्या में सहायता लें')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/support'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: Text(_t('Notifications', 'सूचनाएं')),
                  subtitle: Text(_t('Ride updates and safety alerts', 'राइड अपडेट और सुरक्षा अलर्ट')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(_t('Notifications', 'सूचनाएं')),
                      content: Text(_t(
                        'Quick Ride uses notifications for ride requests, driver updates and safety messages. Manage notification permission in your Android app settings.',
                        'Quick Ride राइड अनुरोध, ड्राइवर अपडेट और सुरक्षा संदेशों के लिए सूचनाओं का उपयोग करता है। Android ऐप सेटिंग में अनुमति बदलें।',
                      )),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _heading(context, _t('Preferences', 'प्राथमिकताएं')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(_t('Appearance', 'दिखावट')),
                  subtitle: Text(_t('System, light or dark theme', 'सिस्टम, लाइट या डार्क थीम')),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  child: SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(_t('System', 'सिस्टम')),
                        icon: const Icon(Icons.settings_suggest_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text(_t('Light', 'लाइट')),
                        icon: const Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(_t('Dark', 'डार्क')),
                        icon: const Icon(Icons.dark_mode_outlined),
                      ),
                    ],
                    selected: {QuickRideCustomerPreferences.themeMode.value},
                    onSelectionChanged: (values) {
                      QuickRideCustomerPreferences.setThemeMode(values.first);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.language_outlined),
                  title: Text(_t('Language', 'भाषा')),
                  subtitle: Text(isHindi ? 'हिन्दी' : 'English'),
                  trailing: DropdownButton<String>(
                    value: QuickRideCustomerPreferences.locale.value.languageCode,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                    ],
                    onChanged: (value) {
                      if (value != null) QuickRideCustomerPreferences.setLanguage(value);
                    },
                  ),
                ),
              ],
            ),
          ),
          _heading(context, _t('Privacy & security', 'गोपनीयता और सुरक्षा')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: Text(_t('Privacy and data', 'गोपनीयता और डेटा')),
                  subtitle: Text(_t('Understand how your account data is handled', 'अपने खाते के डेटा के उपयोग की जानकारी')),
                  onTap: () => showAboutDialog(
                    context: context,
                    applicationName: 'Quick Ride',
                    applicationVersion: '0.1.0',
                    children: [
                      Text(_t(
                        'Account deletion removes profile information where possible. Ride, safety and financial records may be retained in anonymized form when required for platform operations or legal obligations.',
                        'खाता हटाने पर जहां संभव हो प्रोफ़ाइल जानकारी हटाई जाती है। प्लेटफ़ॉर्म संचालन या कानूनी आवश्यकताओं के लिए राइड, सुरक्षा और वित्तीय रिकॉर्ड अनाम रूप में सुरक्षित रखे जा सकते हैं।',
                      )),
                    ],
                  ),
                ),
                if (user != null) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.delete_forever_outlined, color: colors.error),
                    title: Text(
                      _t('Delete account', 'खाता हटाएं'),
                      style: TextStyle(color: colors.error),
                    ),
                    subtitle: Text(_t(
                      'Permanently disable your Quick Ride account',
                      'अपना Quick Ride खाता स्थायी रूप से बंद करें',
                    )),
                    trailing: _deleting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: _deleting ? null : _deleteAccount,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _t(
              'Driver and administrator access are granted separately and cannot be enabled from Customer settings.',
              'ड्राइवर और एडमिन की अनुमति अलग से दी जाती है और Customer सेटिंग से सक्षम नहीं की जा सकती।',
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
          ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 3),
    );
  }
}
