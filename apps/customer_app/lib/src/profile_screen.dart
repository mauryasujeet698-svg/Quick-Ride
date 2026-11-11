import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../customer_preferences.dart';
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

  String _t(String english, String hindi) =>
      QuickRideCustomerPreferences.locale.value.languageCode == 'hi'
          ? hindi
          : english;

  Future<void> _editPersonalDetails() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_t(
            'Sign in to edit your personal details.',
            'व्यक्तिगत जानकारी बदलने के लिए साइन इन करें।',
          )),
        ),
      );
      return;
    }
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final name = TextEditingController(
      text: (metadata['full_name'] ?? metadata['name'] ?? '').toString(),
    );
    final phone = TextEditingController(
      text: (metadata['phone_number'] ?? '').toString(),
    );
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_t('Personal details', 'व्यक्तिगत जानकारी')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: _t('Full name', 'पूरा नाम'),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: _t('Contact number', 'संपर्क नंबर'),
                  prefixIcon: const Icon(Icons.phone_outlined),
                  helperText: _t(
                    'This number is saved as profile information; it is not phone-verified.',
                    'यह नंबर प्रोफ़ाइल जानकारी के रूप में सेव होगा; इसका फोन सत्यापन नहीं हुआ है।',
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_t('Cancel', 'रद्द करें')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_t('Save', 'सेव करें')),
            ),
          ],
        ),
      );
      if (save != true || !mounted) return;
      final fullName = name.text.trim();
      final phoneNumber = phone.text.trim();
      if (phoneNumber.isNotEmpty &&
          !RegExp(r'^[+0-9][0-9 ()-]+$').hasMatch(phoneNumber)) {
        throw StateError(
          _t('Enter a valid contact number.', 'सही संपर्क नंबर दर्ज करें।'),
        );
      }
      await QuickRideBackend.client.auth.updateUser(
        UserAttributes(data: {
          'full_name': fullName,
          'phone_number': phoneNumber,
        }),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t(
              'Personal details updated.',
              'व्यक्तिगत जानकारी अपडेट हो गई।',
            )),
          ),
        );
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t(
              'Could not update your details: $error',
              'जानकारी अपडेट नहीं हो सकी: $error',
            )),
          ),
        );
      }
    } finally {
      name.dispose();
      phone.dispose();
    }
  }

  Future<void> _openSafetyCentre() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_t(
            'Sign in to access ride safety tools.',
            'राइड सुरक्षा सुविधाओं के लिए साइन इन करें।',
          )),
        ),
      );
      return;
    }
    try {
      final rows = await QuickRideBackend.client
          .from('rides')
          .select('id,status,created_at')
          .eq('customer_id', user.id)
          .inFilter('status', const [
            'requested',
            'searching',
            'offered',
            'accepted',
            'driver_arriving',
            'arrived',
            'in_progress',
          ])
          .order('created_at', ascending: false)
          .limit(1);
      if (!mounted) return;
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t(
              'Trip sharing and SOS are available while a ride is active.',
              'ट्रिप शेयरिंग और SOS सक्रिय राइड के दौरान उपलब्ध हैं।',
            )),
          ),
        );
        return;
      }
      final rideId = rows.first['id']?.toString();
      if (rideId == null || rideId.isEmpty) {
        throw StateError('The active ride could not be identified.');
      }
      context.go('/ride/$rideId');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t(
              'Safety tools could not be opened: $error',
              'सुरक्षा सुविधाएं नहीं खुल सकीं: $error',
            )),
          ),
        );
      }
    }
  }

  Future<void> _showSavedPlaces() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ValueListenableBuilder<List<Map<String, dynamic>>>(
          valueListenable: QuickRideCustomerPreferences.savedPlaces,
          builder: (context, places, _) => Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved places',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        )),
                const SizedBox(height: 8),
                if (places.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text('Save a place from Recent places on the home screen.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: places.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final place = places[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.favorite_rounded,
                              color: Color(0xFFE45872)),
                          title: Text(place['name'].toString()),
                          subtitle: Text(place['address'].toString()),
                          trailing: IconButton(
                            tooltip: 'Remove saved place',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () =>
                                QuickRideCustomerPreferences.removeSavedPlace(place),
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            this.context.go('/book', extra: {
                              'pickup': {
                                'longitude': place['longitude'],
                                'latitude': place['latitude'],
                                'address': place['address'],
                                'pincode': place['postalCode'],
                              },
                            });
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFareHistory() async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('Sign in to view your fare history.', 'किराया इतिहास देखने के लिए साइन इन करें।'))),
      );
      return;
    }
    try {
      final rows = await QuickRideBackend.client
          .from('rides')
          .select('id,created_at,status,estimated_fare,final_fare,currency')
          .eq('customer_id', user.id)
          .order('created_at', ascending: false)
          .limit(30);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fare history',
                      style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          )),
                  const SizedBox(height: 8),
                  if (rows.isEmpty)
                    const Expanded(
                      child: Center(child: Text('Your completed ride fares will appear here.')),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final row = Map<String, dynamic>.from(rows[index]);
                          final id = row['id'].toString();
                          final date = DateTime.tryParse(row['created_at'].toString());
                          final fare = row['final_fare'] ?? row['estimated_fare'];
                          final currency = (row['currency'] ?? 'INR').toString();
                          final amount = fare is num
                              ? (currency == 'INR' ? '₹' : currency + ' ') + fare.toStringAsFixed(2)
                              : 'Fare pending';
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.receipt_long_outlined),
                            title: Text(amount,
                                style: const TextStyle(fontWeight: FontWeight.w800)),
                            subtitle: Text(
                              (date == null ? '' : date.toLocal().toString().substring(0, 16) + ' · ') +
                                  row['status'].toString().replaceAll('_', ' '),
                            ),
                            trailing: IconButton(
                              tooltip: 'Share fare summary',
                              icon: const Icon(Icons.share_outlined),
                              onPressed: () => SharePlus.instance.share(
                                ShareParams(
                                  text: 'Quick Ride fare summary\nRide: ' + id +
                                      '\nDate: ' + (date?.toLocal().toString() ?? 'Unavailable') +
                                      '\nStatus: ' + row['status'].toString() +
                                      '\nFare: ' + amount,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fare history could not be loaded: ' + error.toString())),
        );
      }
    }
  }


  Widget _profileOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructive ? colors.error : colors.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minVerticalPadding: 10,
        leading: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: destructive ? colors.errorContainer : colors.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: destructive ? colors.onErrorContainer : colors.onPrimaryContainer),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: destructive ? colors.error : colors.onSurface,
          ),
        ),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: destructive ? colors.error : colors.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }

  Future<void> _showFavouritePlaces() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ValueListenableBuilder<List<Map<String, dynamic>>>(
          valueListenable: QuickRideCustomerPreferences.savedPlaces,
          builder: (context, places, _) {
            final favourites = places.where((place) => place['is_favorite'] == true).toList();
            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.55,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t('Favourite places', 'पसंदीदा स्थान'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    if (favourites.isEmpty)
                      Expanded(
                        child: Center(
                          child: Text(_t(
                            'Tap the heart beside a recent place on Home to save it here.',
                            'यहां सेव करने के लिए होम स्क्रीन पर हाल के स्थान के पास दिल वाले आइकन पर टैप करें।',
                          )),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.separated(
                          itemCount: favourites.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final place = favourites[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.favorite_rounded, color: Color(0xFFE45872)),
                              title: Text(place['name'].toString()),
                              subtitle: Text(place['address'].toString()),
                              trailing: IconButton(
                                tooltip: _t('Remove favourite', 'पसंदीदा से हटाएं'),
                                icon: const Icon(Icons.favorite_border_rounded),
                                onPressed: () => QuickRideCustomerPreferences.removeSavedPlace(place),
                              ),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                this.context.go('/book', extra: {
                                  'pickup': {
                                    'longitude': place['longitude'],
                                    'latitude': place['latitude'],
                                    'address': place['address'],
                                    'pincode': place['postalCode'],
                                  },
                                });
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showPayments() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _t('Payments', 'भुगतान'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.payments_outlined),
                title: Text(_t('Cash payment', 'नकद भुगतान')),
                subtitle: Text(_t(
                  'Cash is available when offered for an eligible ride.',
                  'पात्र राइड के लिए उपलब्ध होने पर नकद भुगतान किया जा सकता है।',
                )),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.credit_card_outlined),
                title: Text(_t('Digital payments', 'डिजिटल भुगतान')),
                subtitle: Text(_t(
                  'Additional payment methods will appear here when enabled.',
                  'अन्य भुगतान विकल्प उपलब्ध होने पर यहां दिखाई देंगे।',
                )),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(_t('Fare history', 'किराया इतिहास')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showFareHistory();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNotificationsInfo() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Notifications', 'सूचनाएं')),
        content: Text(_t(
          'Quick Ride uses notifications for ride requests, driver updates and safety messages. You can manage notification permission from your Android app settings.',
          'Quick Ride राइड अनुरोध, ड्राइवर अपडेट और सुरक्षा संदेशों के लिए सूचनाओं का उपयोग करता है। आप Android ऐप सेटिंग में सूचना अनुमति बदल सकते हैं।',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(_t('Got it', 'समझ गया')),
          ),
        ],
      ),
    );
  }

  Future<void> _shareApp() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _t(
            'Try Quick Ride for local rides and easy trip booking.',
            'स्थानीय राइड और आसान ट्रिप बुकिंग के लिए Quick Ride आज़माएं।',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Could not open the share menu: $error', 'शेयर मेन्यू नहीं खुल सका: $error'))),
        );
      }
    }
  }

  Future<void> _checkForUpdates() async {
    final uri = Uri.parse('https://github.com/mauryasujeet698-svg/Quick-Ride/releases');
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Could not open the updates page.', 'अपडेट पेज नहीं खुल सका।'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Could not check for updates: $error', 'अपडेट नहीं देख सके: $error'))),
        );
      }
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Sign out of Quick Ride?', 'Quick Ride से साइन आउट करें?')),
        content: Text(_t(
          'You will be signed out on this device. Your account and ride records will remain available when you sign in again. Signing out does not cancel an active ride.',
          'इस डिवाइस पर आपका साइन-इन समाप्त हो जाएगा। दोबारा साइन-इन करने पर आपका खाता और राइड रिकॉर्ड उपलब्ध रहेंगे। साइन आउट करने से सक्रिय राइड रद्द नहीं होगी।',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('Sign out', 'साइन आउट')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await QuickRideAuth.signOut();
      if (mounted) context.go('/');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Could not sign out: $error', 'साइन आउट नहीं हो सका: $error'))),
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    return Scaffold(
      appBar: AppBar(title: Text(_t('Profile', 'प्रोफ़ाइल'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (user == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: QuickRideBackend.isInitialized
                      ? () async {
                          try {
                            await QuickRideAuth.signInWithGoogle(
                              redirectTo: 'in.quickride.customer://login-callback',
                            );
                          } catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_t('Sign-in failed: $error', 'साइन-इन विफल: $error'))),
                              );
                            }
                          }
                        }
                      : null,
                  icon: const Icon(Icons.login_rounded),
                  label: Text(_t('Sign in / Create account', 'साइन इन / खाता बनाएं')),
                ),
              ),
            )
          else
            _profileOption(
              icon: Icons.person_outline_rounded,
              title: _t('Personal details', 'व्यक्तिगत जानकारी'),
              subtitle: user.email ?? _t('Manage your account details', 'अपने खाते की जानकारी प्रबंधित करें'),
              onTap: _editPersonalDetails,
            ),
          _profileOption(
            icon: Icons.route_outlined,
            title: _t('My rides', 'मेरी राइड'),
            subtitle: _t('Current, completed and cancelled rides', 'वर्तमान, पूरी और रद्द राइड'),
            onTap: () => context.go('/my-rides'),
          ),
          _profileOption(
            icon: Icons.bookmark_border_rounded,
            title: _t('Saved addresses', 'सेव किए गए पते'),
            subtitle: _t('Home, work and other saved locations', 'घर, काम और अन्य सेव किए गए स्थान'),
            onTap: _showSavedPlaces,
          ),
          _profileOption(
            icon: Icons.favorite_border_rounded,
            title: _t('Favourite places', 'पसंदीदा स्थान'),
            subtitle: _t('Quickly choose places you have loved', 'अपने पसंदीदा स्थान जल्दी चुनें'),
            onTap: _showFavouritePlaces,
          ),
          _profileOption(
            icon: Icons.receipt_long_outlined,
            title: _t('Fare history', 'किराया इतिहास'),
            subtitle: _t('View and share your ride fare summaries', 'राइड किराया विवरण देखें और साझा करें'),
            onTap: _showFareHistory,
          ),
          _profileOption(
            icon: Icons.account_balance_wallet_outlined,
            title: _t('Payments', 'भुगतान'),
            subtitle: _t('Payment options and fare records', 'भुगतान विकल्प और किराया रिकॉर्ड'),
            onTap: _showPayments,
          ),
          _profileOption(
            icon: Icons.shield_outlined,
            title: _t('Safety centre', 'सुरक्षा केंद्र'),
            subtitle: _t('Live trip sharing, driver tracking and emergency SOS', 'लाइव ट्रिप शेयरिंग, ड्राइवर ट्रैकिंग और आपातकालीन SOS'),
            onTap: _openSafetyCentre,
          ),
          _profileOption(
            icon: Icons.support_agent_outlined,
            title: _t('Help & support', 'सहायता और सपोर्ट'),
            subtitle: _t('Get help with a ride or a general issue', 'राइड या अन्य समस्या में सहायता लें'),
            onTap: () => context.go('/support'),
          ),
          _profileOption(
            icon: Icons.notifications_outlined,
            title: _t('Notifications', 'सूचनाएं'),
            subtitle: _t('Ride updates and safety alerts', 'राइड अपडेट और सुरक्षा अलर्ट'),
            onTap: _showNotificationsInfo,
          ),
          _profileOption(
            icon: Icons.settings_outlined,
            title: _t('Settings', 'सेटिंग्स'),
            subtitle: _t('Appearance, language and account preferences', 'दिखावट, भाषा और खाते की प्राथमिकताएं'),
            onTap: () => context.push('/settings'),
          ),
          _profileOption(
            icon: Icons.privacy_tip_outlined,
            title: _t('Privacy policy', 'गोपनीयता नीति'),
            subtitle: _t('How Quick Ride handles your information', 'Quick Ride आपकी जानकारी का उपयोग कैसे करता है'),
            onTap: () => context.push('/privacy-policy'),
          ),
          _profileOption(
            icon: Icons.description_outlined,
            title: _t('Terms & Conditions', 'नियम और शर्तें'),
            subtitle: _t('Terms for using Quick Ride', 'Quick Ride के उपयोग की शर्तें'),
            onTap: () => context.push('/terms'),
          ),
          _profileOption(
            icon: Icons.info_outline_rounded,
            title: _t('About Quick Ride', 'Quick Ride के बारे में'),
            subtitle: _t('App information and version', 'ऐप की जानकारी और संस्करण'),
            onTap: () => context.push('/about'),
          ),
          _profileOption(
            icon: Icons.share_outlined,
            title: _t('Share app', 'ऐप साझा करें'),
            subtitle: _t('Invite friends to try Quick Ride', 'दोस्तों को Quick Ride आज़माने के लिए आमंत्रित करें'),
            onTap: _shareApp,
          ),
          _profileOption(
            icon: Icons.system_update_alt_rounded,
            title: _t('App updates', 'ऐप अपडेट'),
            subtitle: _t('Check published Quick Ride releases', 'Quick Ride के नए रिलीज़ देखें'),
            onTap: _checkForUpdates,
          ),
          if (user != null)
            _profileOption(
              icon: Icons.logout_rounded,
              title: _t('Sign out', 'साइन आउट'),
              subtitle: _t('Sign out of this device', 'इस डिवाइस से साइन आउट करें'),
              onTap: _confirmSignOut,
              destructive: true,
            ),
        ],
      ),
      bottomNavigationBar: const CustomerNavigationBar(selectedIndex: 3),
    );
  }
}

class CustomerSettingsScreen extends StatefulWidget {
  const CustomerSettingsScreen({super.key});

  @override
  State<CustomerSettingsScreen> createState() => _CustomerSettingsScreenState();
}

class _CustomerSettingsScreenState extends State<CustomerSettingsScreen> {
  bool _deleting = false;

  String _t(String english, String hindi) =>
      QuickRideCustomerPreferences.locale.value.languageCode == 'hi' ? hindi : english;

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Delete your account?', 'अपना खाता हटाएं?')),
        content: Text(_t(
          'This permanently disables future sign-in and removes your profile details where possible. Ride, payment, safety and legally required records may need to be retained in an anonymized form. This action cannot be undone.',
          'इससे आगे साइन-इन स्थायी रूप से बंद हो जाएगा और जहां संभव हो आपकी प्रोफ़ाइल जानकारी हटाई जाएगी। आवश्यक राइड, भुगतान, सुरक्षा या कानूनी रिकॉर्ड अनाम रूप में सुरक्षित रखे जा सकते हैं। यह कार्रवाई वापस नहीं ली जा सकती।',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('Delete account', 'खाता हटाएं')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      final resultResponse = await QuickRideBackend.invoke('delete-account', body: const {});
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

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t('Settings', 'सेटिंग्स'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(_t('Appearance', 'दिखावट')),
                  subtitle: Text(_t('Choose how Quick Ride looks', 'Quick Ride की थीम चुनें')),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: ValueListenableBuilder<ThemeMode>(
                    valueListenable: QuickRideCustomerPreferences.themeMode,
                    builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                      segments: [
                        ButtonSegment(value: ThemeMode.system, label: Text(_t('System', 'सिस्टम')), icon: const Icon(Icons.settings_suggest_outlined)),
                        ButtonSegment(value: ThemeMode.light, label: Text(_t('Light', 'लाइट')), icon: const Icon(Icons.light_mode_outlined)),
                        ButtonSegment(value: ThemeMode.dark, label: Text(_t('Dark', 'डार्क')), icon: const Icon(Icons.dark_mode_outlined)),
                      ],
                      selected: {mode},
                      onSelectionChanged: (values) => QuickRideCustomerPreferences.setThemeMode(values.first),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ValueListenableBuilder<Locale>(
                  valueListenable: QuickRideCustomerPreferences.locale,
                  builder: (context, locale, _) => ListTile(
                    leading: const Icon(Icons.language_outlined),
                    title: Text(_t('Language', 'भाषा')),
                    subtitle: Text(locale.languageCode == 'hi' ? 'हिन्दी' : 'English'),
                    trailing: DropdownButton<String>(
                      value: locale.languageCode,
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
                ),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(_t('Notification preferences', 'सूचना प्राथमिकताएं')),
              subtitle: Text(_t('Manage notification permission in device settings', 'डिवाइस सेटिंग में सूचना अनुमति प्रबंधित करें')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(_t('Notifications', 'सूचनाएं')),
                  content: Text(_t(
                    'Ride updates and safety alerts use Android notification permission. To change permission, open Android Settings → Apps → Quick Ride → Notifications.',
                    'राइड अपडेट और सुरक्षा अलर्ट के लिए Android सूचना अनुमति आवश्यक है। अनुमति बदलने के लिए Android Settings → Apps → Quick Ride → Notifications खोलें।',
                  )),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(_t('OK', 'ठीक है'))),
                  ],
                ),
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.location_on_outlined),
              title: Text(_t('Location preferences', 'लोकेशन प्राथमिकताएं')),
              subtitle: Text(_t('Control location permission for pickup and maps', 'पिकअप और मैप के लिए लोकेशन अनुमति नियंत्रित करें')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(_t('Location access', 'लोकेशन अनुमति')),
                  content: Text(_t(
                    'Quick Ride uses your location to help set a pickup point and provide ride-related map features. You can change location permission in Android Settings → Apps → Quick Ride → Permissions.',
                    'Quick Ride पिकअप स्थान और राइड मैप सुविधाओं के लिए आपकी लोकेशन का उपयोग करता है। अनुमति बदलने के लिए Android Settings → Apps → Quick Ride → Permissions खोलें।',
                  )),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(_t('OK', 'ठीक है'))),
                  ],
                ),
              ),
            ),
          ),
          if (user != null)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: colors.error),
                title: Text(
                  _t('Delete account', 'खाता हटाएं'),
                  style: TextStyle(color: colors.error, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(_t('Permanently disable your Quick Ride account', 'अपना Quick Ride खाता स्थायी रूप से बंद करें')),
                trailing: _deleting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right),
                onTap: _deleting ? null : _deleteAccount,
              ),
            ),
        ],
      ),
    );
  }
}

class CustomerInformationScreen extends StatelessWidget {
  const CustomerInformationScreen({super.key, required this.page});

  final String page;

  @override
  Widget build(BuildContext context) {
    final isHindi = QuickRideCustomerPreferences.locale.value.languageCode == 'hi';
    final title = switch (page) {
      'privacy' => isHindi ? 'गोपनीयता नीति' : 'Privacy policy',
      'terms' => isHindi ? 'नियम और शर्तें' : 'Terms & Conditions',
      _ => isHindi ? 'Quick Ride के बारे में' : 'About Quick Ride',
    };

    final sections = page == 'privacy'
        ? <(String, String)>[
            ('Information used by Quick Ride', 'Quick Ride may process your Google account identifier and email address, any profile name or contact number you choose to provide, pickup and destination details, ride status, fare information, support requests, safety events and the device token used to deliver notifications.'),
            ('Location and maps', 'When you use location features, your device location may be used to set or correct a pickup point. Pickup and destination details are used to arrange a ride and may be shared with the assigned driver. Map display, place search, reverse geocoding and route requests are provided through Mapbox services. You can manage location permission in your device settings.'),
            ('Service providers', 'Quick Ride uses Google sign-in for authentication, Supabase for account and ride services, Mapbox for map and location services, and Firebase Cloud Messaging for push notifications. These services process the information needed to provide their respective functions.'),
            ('Sharing and safety', 'Ride details are made available to the assigned driver when needed to fulfil a booking. Information may also be processed by service providers that operate authentication, maps, hosting and notifications. Information connected with a support request or safety report is used to review and respond to that issue.'),
            ('Saved places and preferences', 'Recent places, saved addresses, favourites, language and theme preferences are stored on your device by the app. You can remove saved places from the app. Clearing app data or uninstalling the app may remove locally stored preferences and places.'),
            ('Retention and account deletion', 'You can request account deletion from Settings. The account-deletion process disables future sign-in and removes profile information where possible. Ride, payment, safety or legally required records may be retained in an anonymized form where necessary for platform operations or legal obligations.'),
            ('Your choices', 'You can edit profile details, remove saved places, change location and notification permissions in device settings, sign out, or request account deletion from Settings.'),
            ('Contact and policy updates', 'For questions or requests about your account, use Help & Support in the app. This policy should be updated when Quick Ride changes its data practices or service providers.'),
          ]
        : page == 'terms'
            ? <(String, String)>[
                ('Using Quick Ride', 'Quick Ride provides tools to explore local ride options, request trips and receive ride updates. You must provide accurate booking information and use the app lawfully.'),
                ('Bookings and availability', 'A search or fare estimate is not a confirmed booking. A ride is confirmed only when the app displays a successful booking status. Vehicle and driver availability may change by location and time.'),
                ('Fares and payments', 'Fare estimates may change when trip details or actual trip conditions change. The applicable fare and supported payment options are shown during the booking or ride flow. You are responsible for paying the confirmed fare through an available payment method.'),
                ('Cancellations and conduct', 'Cancellation options and any applicable charges are shown in the ride flow. Customers must treat drivers respectfully, provide a safe and accurate pickup point, and must not use Quick Ride for unlawful or unsafe purposes.'),
                ('Location, notifications and connectivity', 'Some features require location permission, internet access or notifications. You can manage permissions in device settings. Network, GPS or third-party service interruptions may affect map display, search, booking or ride updates.'),
                ('Account and access', 'You are responsible for access to your Google account and for keeping your account details accurate. You may sign out at any time or request account deletion from Settings. Certain operational, safety or legally required records may be retained after deletion.'),
                ('Changes and support', 'Features, availability and these terms may change as Quick Ride evolves. Use Help & Support in the app to report a problem or ask a question.'),
              ]
            : <(String, String)>[
                ('About the app', 'Quick Ride is a customer ride-booking application designed to help people explore local ride options, request trips and follow ride updates.'),
                ('Features', 'The app includes pickup and destination selection, map-based location tools, vehicle discovery, ride history, saved places, safety tools and customer support. Availability depends on the configured service area.'),
                ('Version', 'Quick Ride Customer · Version 0.1.0 · Build 1'),
              ];

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          for (final section in sections) ...[
            Text(
              section.$1,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(section.$2, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5)),
            const SizedBox(height: 20),
          ],
          if (page == 'privacy' || page == 'terms')
            Text(
              'Last reviewed: November 2026',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
