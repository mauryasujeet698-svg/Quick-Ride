import 'dart:async';
import 'dart:math';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});
  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final _pincode = TextEditingController();
  final _registration = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _color = TextEditingController();
  final _otp = TextEditingController();
  bool _busy = false;
  bool _online = false;
  bool _syncingAvailability = false;
  String? _availabilitySyncKey;
  Map<String, dynamic>? _earnings;
  bool _earningsLoading = false;
  bool _earningsLoaded = false;
  String? _earningsError;
  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  StreamSubscription<dynamic>? _locationSubscription;
  StreamSubscription<dynamic>? _authSubscription;
  DateTime _lastLocationSent = DateTime.fromMillisecondsSinceEpoch(0);
  String? _message;
  List<Map<String, dynamic>> _documents = [];
  bool _loadingDocuments = false;
  String? _uploadingDocumentType;
  final Map<String, DateTime?> _documentExpiryDates = {};

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (!mounted) return;
        setState(() {});
        if (QuickRideAuth.currentUser == null) {
          _locationSubscription?.cancel();
          _locationSubscription = null;
          _online = false;
          _documents = [];
          _earnings = null;
          _earningsLoaded = false;
          _earningsError = null;
        } else {
          _loadCategories();
          _loadDocuments();
        }
      });
      _loadCategories();
      if (QuickRideAuth.currentUser != null) _loadDocuments();
    }
  }

  @override
  void dispose() {
    _pincode.dispose();
    _registration.dispose();
    _make.dispose();
    _model.dispose();
    _color.dispose();
    _otp.dispose();
    _locationSubscription?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final rows = await QuickRideBackend.client
          .from('vehicle_categories')
          .select('id,code,name')
          .eq('is_active', true)
          .order('id');
      if (!mounted) return;
      setState(() {
        _categories = rows;
        _categoryId = rows.isEmpty ? null : (rows.first['id'] as num).toInt();
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Vehicle options unavailable: $error');
    }
  }

  Future<void> _loadEarnings({bool force = false}) async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null ||
        _earningsLoading || (_earningsLoaded && !force)) {
      return;
    }
    _earningsLoading = true;
    try {
      final result = await _invoke('get_earnings');
      if (!mounted) return;
      setState(() {
        _earnings = result;
        _earningsLoaded = true;
        _earningsError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _earningsLoaded = true;
          _earningsError = error.toString();
        });
      }
    } finally {
      _earningsLoading = false;
      if (mounted) setState(() {});
    }
  }

  String _money(Object? value) {
    final amount = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    return amount == null ? '₹—' : '₹' + amount.toStringAsFixed(2);
  }

  Widget _earningsCard() {
    final totals = _earnings?['totals'] as Map<String, dynamic>? ?? {};
    final inr = totals['INR'] as Map<String, dynamic>? ?? {};
    final subscriptions = _earnings?['subscriptions'] as List<dynamic>? ?? [];
    final payments = _earnings?['payments'] as List<dynamic>? ?? [];
    final ledger = _earnings?['ledger'] as List<dynamic>? ?? [];
    final recentRides = _earnings?['recent_completed_rides'] as List<dynamic>? ?? [];
    final completedCount = _earnings?['completed_ride_count'] ?? 0;
    final recentWindowCount = _earnings?['recent_window_ride_count'] ?? 0;
    final latestSubscription = subscriptions.isEmpty
        ? null
        : Map<String, dynamic>.from(subscriptions.first as Map);
    final latestPayment = payments.isEmpty
        ? null
        : Map<String, dynamic>.from(payments.first as Map);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Earnings & settlements',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh earnings',
                  onPressed: _earningsLoading ? null : () => _loadEarnings(force: true),
                  icon: _earningsLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_earningsError != null)
              Text(
                'Earnings could not be loaded: $_earningsError',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (_earnings == null)
              const LinearProgressIndicator()
            else ...[
              Text('Showing the latest $recentWindowCount of $completedCount completed rides'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _earningMetric('Last 30 rides · fare', _money(inr['gross_fare'])),
                  _earningMetric('Last 30 · commission', _money(inr['platform_commission'])),
                  _earningMetric('After commission*', _money(inr['after_commission'])),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '*Recent-ride accounting estimate only. This is not confirmation of a bank payout.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (latestSubscription != null) ...[
                const Divider(height: 24),
                Text('Latest driver subscription', style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${_money(latestSubscription['amount'])} · ${latestSubscription['status'].toString().replaceAll('_', ' ')}',
                ),
                if (latestSubscription['period_end'] != null)
                  Text(
                    'Period ends ${DateTime.tryParse(latestSubscription['period_end'].toString())?.toLocal().toString().substring(0, 10) ?? latestSubscription['period_end']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              if (latestPayment != null) ...[
                const Divider(height: 24),
                Text('Latest payment record', style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${_money(latestPayment['amount'])} · ${latestPayment['payment_purpose'].toString().replaceAll('_', ' ')}',
                ),
                Text(
                  latestPayment['status'].toString().replaceAll('_', ' '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (ledger.isNotEmpty) ...[
                const Divider(height: 24),
                Text('Recent ledger entries', style: Theme.of(context).textTheme.titleMedium),
                ...ledger.take(3).map((item) {
                  final entry = Map<String, dynamic>.from(item as Map);
                  final sign = entry['direction'] == 'credit' ? '+' : '−';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry['description']?.toString() ??
                        entry['entry_type'].toString().replaceAll('_', ' ')),
                    subtitle: Text(entry['status'].toString().replaceAll('_', ' ')),
                    trailing: Text(sign + _money(entry['amount'])),
                  );
                }),
              ],
              if (recentRides.isNotEmpty) ...[
                const Divider(height: 24),
                Text('Recent completed rides', style: Theme.of(context).textTheme.titleMedium),
                ...recentRides.take(3).map((item) {
                  final ride = Map<String, dynamic>.from(item as Map);
                  final date = DateTime.tryParse(ride['completed_at']?.toString() ?? '');
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Ride ${ride['id'].toString().substring(0, 8)}'),
                    subtitle: Text(date?.toLocal().toString().substring(0, 16) ?? 'Completed'),
                    trailing: Text(_money(ride['final_fare'] ?? ride['estimated_fare'])),
                  );
                }),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _earningMetric(String label, String value) => Container(
        constraints: const BoxConstraints(minWidth: 100, maxWidth: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
      );

  Future<Map<String, dynamic>> _invoke(
    String action, [
    Map<String, dynamic> values = const {},
  ]) async {
    final response = await QuickRideBackend.invoke(
      'driver-ride-actions',
      body: {'action': action, ...values},
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (_categoryId == null ||
        _registration.text.trim().isEmpty ||
        _make.text.trim().isEmpty ||
        _model.text.trim().isEmpty) {
      setState(() => _message = 'Complete the vehicle details first.');
      return;
    }
    await _run(() async {
      await _invoke('apply_driver', {
        'vehicleCategoryId': _categoryId,
        'vehicleRegistration': _registration.text.trim(),
        'vehicleMake': _make.text.trim(),
        'vehicleModel': _model.text.trim(),
        'vehicleColor': _color.text.trim(),
      });
      await _requestPincode();
      await _loadDocuments();
      if (mounted) {
        setState(() => _message = 'Application submitted. Admin review is required before you can go online.');
      }
    });
  }

  Future<void> _requestPincode() async {
    final pin = _pincode.text.trim();
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(pin)) {
      throw StateError('Enter a valid six-digit service pincode.');
    }
    await _invoke('request_service_pincode', {
      'pincode': pin,
      'isPrimary': true,
    });
  }

  Future<void> _loadDocuments() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) return;
    if (mounted) setState(() => _loadingDocuments = true);
    try {
      final result = await _invoke('list_documents');
      final rows = (result['documents'] as List<dynamic>? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (mounted) setState(() => _documents = rows);
    } catch (error) {
      if (mounted) setState(() => _message = 'Document status could not be loaded: $error');
    } finally {
      if (mounted) setState(() => _loadingDocuments = false);
    }
  }

  Future<void> _uploadDocument(String documentType) async {
    final user = QuickRideAuth.currentUser;
    if (user == null) {
      setState(() => _message = 'Sign in before uploading driver documents.');
      return;
    }
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      );
      if (file == null) return;
      final fileLength = file.lengthSync() ?? await file.length();
      if (fileLength == null || fileLength < 1) {
        throw StateError('The selected file could not be read. Please choose it again.');
      }
      if (fileLength > 5 * 1024 * 1024) {
        throw StateError('Each document must be 5 MB or smaller.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('The selected file is empty. Please choose it again.');
      }
      final extension = (file.extension ?? '').toLowerCase();
      final contentType = switch (extension) {
        'pdf' => 'application/pdf',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        _ => '',
      };
      if (contentType.isEmpty) throw StateError('Choose a PDF, JPG or PNG file.');
      final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
      final objectPath = user.id + '/' + documentType + '/' +
          DateTime.now().millisecondsSinceEpoch.toString() + '_' + suffix + '_' + safeName;

      setState(() {
        _uploadingDocumentType = documentType;
        _message = null;
      });
      await QuickRideBackend.client.storage
          .from('driver-documents')
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              contentType: contentType,
              upsert: false,
            ),
          );
      await _invoke('register_document', {
        'documentType': documentType,
        'objectPath': objectPath,
        'contentType': contentType,
        'byteSize': bytes.length,
        'expiresAt': (_documentExpiryDates[documentType] ??
                _existingDocumentExpiry(documentType))
            ?.toIso8601String(),
      });
      await _loadDocuments();
      if (mounted) {
        setState(() => _message = 'Document uploaded. It is waiting for Admin review.');
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Document upload failed: $error');
    } finally {
      if (mounted) setState(() => _uploadingDocumentType = null);
    }
  }

  DateTime? _existingDocumentExpiry(String documentType) {
    final matches = _documents.where(
      (document) => document['document_type'] == documentType,
    );
    if (matches.isEmpty || matches.first['expires_at'] == null) return null;
    return DateTime.tryParse(matches.first['expires_at'].toString());
  }

  String _formatDocumentDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return year + '-' + month + '-' + day;
  }

  Future<void> _chooseDocumentExpiry(String documentType) async {
    final now = DateTime.now();
    final initial = _documentExpiryDates[documentType] ??
        _existingDocumentExpiry(documentType) ??
        now.add(const Duration(days: 365));
    final selected = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 30),
      helpText: 'Select document expiry date',
    );
    if (selected != null && mounted) {
      setState(() => _documentExpiryDates[documentType] = selected);
    }
  }

  Widget _documentsPanel() {
    const requiredDocuments = <String, String>{
      'driving_license': 'Driving licence',
      'vehicle_rc': 'Vehicle registration certificate',
      'insurance': 'Vehicle insurance',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Required verification documents',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 5),
            const Text('Upload a clear PDF, JPG or PNG for each item. Maximum 5 MB per file. Add the expiry date where the document has one. Admin approval is required before you can go online.'),
            if (_loadingDocuments) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            ...requiredDocuments.entries.map((entry) {
              final matches = _documents.where(
                (document) => document['document_type'] == entry.key,
              ).toList();
              final latest = matches.isEmpty ? null : matches.first;
              final status = latest?['verification_status']?.toString() ?? 'not_uploaded';
              final existingExpiry = _existingDocumentExpiry(entry.key);
              final selectedExpiry = _documentExpiryDates[entry.key] ?? existingExpiry;
              final isExpired = existingExpiry != null &&
                  DateUtils.dateOnly(existingExpiry).isBefore(DateUtils.dateOnly(DateTime.now()));
              final isApproved = status == 'approved' && !isExpired;
              final isUploading = _uploadingDocumentType == entry.key;
              final statusLabel = isExpired
                  ? 'Expired'
                  : status == 'not_uploaded'
                      ? 'Not uploaded'
                      : status.replaceAll('_', ' ');
              final expiryLabel = selectedExpiry == null
                  ? 'Expiry date optional'
                  : 'Expires: ' + _formatDocumentDate(selectedExpiry);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isApproved ? Icons.verified_rounded : Icons.description_outlined,
                  color: isApproved ? Colors.green : null,
                ),
                title: Text(entry.value),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(statusLabel),
                    Text(expiryLabel),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _busy || _uploadingDocumentType != null
                          ? null
                          : () => _chooseDocumentExpiry(entry.key),
                      icon: const Icon(Icons.calendar_month_outlined, size: 16),
                      label: Text(
                        selectedExpiry == null ? 'Set expiry date' : 'Change expiry date',
                      ),
                    ),
                  ],
                ),
                trailing: isUploading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : isApproved
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : OutlinedButton(
                            onPressed: _busy || _uploadingDocumentType != null
                                ? null
                                : () => _uploadDocument(entry.key),
                            child: Text(status == 'not_uploaded' ? 'Upload' : 'Replace'),
                          ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _setOnline(bool online) async {
    await _run(() async {
      if (online) {
        await _invoke('set_online', {'pincode': _pincode.text.trim()});
        _online = true;
        _startLocationUpdates();
      } else {
        await _invoke('set_offline');
        _online = false;
        await _locationSubscription?.cancel();
        _locationSubscription = null;
      }
      if (mounted) setState(() => _message = online ? 'You are online.' : 'You are offline.');
    });
  }

  Future<void> _syncAvailabilityFromProfile(
    Map<String, dynamic> driver,
  ) async {
    final status = driver['availability_status']?.toString() ?? 'offline';
    final pincodeId = driver['active_pincode_id'];
    final shouldShareLocation = status == 'online' || status == 'busy';
    final key = '$status|$pincodeId';
    if (_syncingAvailability || _availabilitySyncKey == key) return;
    _syncingAvailability = true;
    _availabilitySyncKey = key;
    try {
      if (shouldShareLocation && pincodeId != null) {
        final row = await QuickRideBackend.client
            .from('service_area_pincodes')
            .select('pincode')
            .eq('id', pincodeId)
            .maybeSingle();
        if (!mounted) return;
        final pin = row?['pincode']?.toString();
        if (pin != null && pin.isNotEmpty) _pincode.text = pin;
        if (!_online) setState(() => _online = true);
        _startLocationUpdates();
      } else {
        if (_online) setState(() => _online = false);
        await _locationSubscription?.cancel();
        _locationSubscription = null;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not restore driver availability: $error');
      }
      _availabilitySyncKey = null;
    } finally {
      _syncingAvailability = false;
    }
  }

  void _startLocationUpdates() {
    if (_locationSubscription != null) return;
    _locationSubscription = QuickRideMaps.watchDriverPosition().listen(
      (position) async {
        final now = DateTime.now();
        if (now.difference(_lastLocationSent) < const Duration(seconds: 8)) return;
        _lastLocationSent = now;
        try {
          await _invoke('update_location', {
            'longitude': position.longitude,
            'latitude': position.latitude,
            'accuracyM': position.accuracy,
            'speedMps': position.speed,
            'headingDegrees': position.heading,
            'recordedAt': position.timestamp.toUtc().toIso8601String(),
          });
        } catch (error) {
          if (mounted) setState(() => _message = 'Location update failed: $error');
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _message = 'GPS stream stopped: $error');
      },
    );
  }

  Future<void> _transition(String action, String rideId) async {
    await _run(() async {
      final values = <String, dynamic>{'rideId': rideId};
      if (action == 'start') values['pickupOtp'] = _otp.text.trim();
      await _invoke(action, values);
      if (action == 'start') _otp.clear();
      if (action == 'complete' && mounted) {
        setState(() => _message = 'Trip completed. Fare was calculated by the server.');
      }
    });
  }

  Widget _previewTile(
    IconData icon,
    String title,
    String subtitle,
  ) =>
      Card(
        child: ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
      );

  Widget _previewScreen() {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick-Ride Driver'),
        actions: [
          IconButton(
            tooltip: 'Sign in',
            onPressed: QuickRideBackend.isInitialized
                ? () => QuickRideAuth.signInWithGoogle(
                      redirectTo: 'in.quickride.driver://login-callback',
                    )
                : null,
            icon: const Icon(Icons.login),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            'Driver partner',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Explore the driver app before connecting your live driver account.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 14),
          Card(
            color: colors.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.visibility_outlined,
                      color: colors.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Preview mode · Read only\n'
                      'Live actions such as going online, accepting rides, '
                      'uploading documents and earnings sync become available '
                      'after Google sign-in and backend setup.',
                      style: TextStyle(color: colors.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Driver dashboard',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _previewTile(
            Icons.toggle_off_outlined,
            'Availability',
            'Online/offline status and approved operating pincode',
          ),
          _previewTile(
            Icons.account_balance_wallet_outlined,
            'Earnings and settlements',
            'Daily earnings, completed trips and settlement summary',
          ),
          const SizedBox(height: 14),
          Text('Ride management',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _previewTile(
            Icons.notifications_active_outlined,
            'Ride offers',
            'View pickup details, expiry and accept or reject offers',
          ),
          _previewTile(
            Icons.alt_route_rounded,
            'Next-ride offers',
            'See possible follow-up rides near the current destination',
          ),
          _previewTile(
            Icons.navigation_outlined,
            'Trip navigation',
            'OpenStreetMap route, live GPS, ETA and spoken directions',
          ),
          _previewTile(
            Icons.pin_outlined,
            'Pickup verification',
            'Verify customer OTP and update each trip status',
          ),
          const SizedBox(height: 14),
          Text('Driver onboarding',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _previewTile(
            Icons.directions_car_outlined,
            'Vehicle registration',
            'Select a vehicle category and submit vehicle information',
          ),
          _previewTile(
            Icons.upload_file_outlined,
            'Document verification',
            'Upload driving licence, RC and insurance for admin review',
          ),
          _previewTile(
            Icons.location_on_outlined,
            'Service pincodes',
            'Apply to operate in additional approved service areas',
          ),
          _previewTile(
            Icons.sos_outlined,
            'Emergency support',
            'Emergency dialer and ride-linked SOS event',
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: QuickRideBackend.isInitialized
                ? () => QuickRideAuth.signInWithGoogle(
                      redirectTo: 'in.quickride.driver://login-callback',
                    )
                : null,
            icon: const Icon(Icons.login),
            label: const Text('Sign in to activate driver features'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (!QuickRideBackend.isInitialized || user == null) {
      return _previewScreen();
    }

    final profile = QuickRideBackend.client
        .from('driver_profiles').stream(primaryKey: ['user_id']).eq('user_id', user.id);
    final offers = QuickRideBackend.client
        .from('ride_offers').stream(primaryKey: ['id']).eq('driver_id', user.id);
    final chainOffers = QuickRideBackend.client
        .from('ride_chain_offers').stream(primaryKey: ['id']).eq('driver_id', user.id);
    final rides = QuickRideBackend.client
        .from('rides').stream(primaryKey: ['id']).eq('driver_id', user.id);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick-Ride Driver'),
        actions: [
          IconButton(onPressed: QuickRideAuth.signOut, icon: const Icon(Icons.logout)),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: profile,
        builder: (context, snapshot) {
          final driver = snapshot.data?.isNotEmpty == true ? snapshot.data!.first : null;
          if (snapshot.connectionState == ConnectionState.waiting && driver == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (driver == null) return _applicationForm();
          final status = driver['verification_status'].toString();
          if (status != 'approved') return _pendingApproval(status);
          unawaited(_syncAvailabilityFromProfile(driver));
          unawaited(_loadEarnings());

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _availabilityCard(),
              const SizedBox(height: 12),
              _earningsCard(),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 20),
              Text('Ride offers', style: Theme.of(context).textTheme.titleLarge),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: offers,
                builder: (context, offerSnapshot) {
                  final rows = (offerSnapshot.data ?? [])
                      .where((row) => row['status'] == 'pending' &&
                          DateTime.tryParse(row['expires_at'].toString())?.isAfter(DateTime.now()) == true)
                      .toList();
                  if (offerSnapshot.hasError) return Text('Offer updates unavailable: ${offerSnapshot.error}');
                  if (!offerSnapshot.hasData) return const LinearProgressIndicator();
                  if (rows.isEmpty) return const Text('No active ride offers.');
                  return Column(children: rows.map(_offerCard).toList());
                },
              ),
              const SizedBox(height: 20),
              Text('Next rides near your destination', style: Theme.of(context).textTheme.titleLarge),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: chainOffers,
                builder: (context, chainSnapshot) {
                  final rows = (chainSnapshot.data ?? [])
                      .where((row) => row['status'] == 'offered' &&
                          DateTime.tryParse(row['expires_at'].toString())?.isAfter(DateTime.now()) == true)
                      .toList();
                  if (chainSnapshot.hasError) return Text('Ride-chain updates unavailable: ${chainSnapshot.error}');
                  if (!chainSnapshot.hasData) return const LinearProgressIndicator();
                  if (rows.isEmpty) return const Text('No nearby next-ride offers.');
                  return Column(children: rows.map(_chainOfferCard).toList());
                },
              ),
              const SizedBox(height: 20),
              Text('Current rides', style: Theme.of(context).textTheme.titleLarge),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: rides,
                builder: (context, rideSnapshot) {
                  if (rideSnapshot.hasError) return Text('Ride status unavailable: ${rideSnapshot.error}');
                  if (!rideSnapshot.hasData) return const LinearProgressIndicator();
                  final active = rideSnapshot.data!.where((row) => [
                    'accepted', 'driver_arriving', 'arrived', 'in_progress',
                  ].contains(row['status'])).toList();
                  if (active.isEmpty) return const Text('No active ride.');
                  return Column(children: active.map(_activeRideCard).toList());
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _applicationForm() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Driver onboarding', style: Theme.of(context).textTheme.headlineSmall),
          const Text('Submit your vehicle details and the pincode where you want to operate. Admin approval is required.'),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: 'Vehicle category'),
            items: _categories.map((row) => DropdownMenuItem(
              value: (row['id'] as num).toInt(),
              child: Text(row['name'].toString()),
            )).toList(),
            onChanged: _busy ? null : (value) => setState(() => _categoryId = value),
          ),
          const SizedBox(height: 8),
          TextField(controller: _registration, decoration: const InputDecoration(labelText: 'Vehicle registration')),
          const SizedBox(height: 8),
          TextField(controller: _make, decoration: const InputDecoration(labelText: 'Vehicle make')),
          const SizedBox(height: 8),
          TextField(controller: _model, decoration: const InputDecoration(labelText: 'Vehicle model')),
          const SizedBox(height: 8),
          TextField(controller: _color, decoration: const InputDecoration(labelText: 'Vehicle colour (optional)')),
          const SizedBox(height: 8),
          TextField(
            controller: _pincode,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Operating pincode', counterText: ''),
          ),
          if (_message != null) Text(_message!),
          FilledButton(
            onPressed: _busy || _categories.isEmpty ? null : _apply,
            child: _busy ? const CircularProgressIndicator() : const Text('Submit driver application'),
          ),
        ],
      );

  Widget _pendingApproval(String status) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.hourglass_top, size: 48),
          Text('Driver application: $status', style: Theme.of(context).textTheme.headlineSmall),
          const Text('Admin verification, approved documents and service-pincode approval are required before going online.'),
          const SizedBox(height: 12),
          _documentsPanel(),
          const SizedBox(height: 12),
          TextField(
            controller: _pincode,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Request another service pincode', counterText: ''),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(_requestPincode),
            child: const Text('Request service pincode'),
          ),
          if (_message != null) Text(_message!),
        ],
      );

  Widget _availabilityCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_online ? 'You are online' : 'You are offline',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _pincode,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'Approved operating pincode', counterText: ''),
              ),
              Wrap(spacing: 8, children: [
                FilledButton(
                  onPressed: _busy || _online ? null : () => _setOnline(true),
                  child: const Text('Go online'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_online ? null : () => _setOnline(false),
                  child: const Text('Go offline'),
                ),
              ]),
            ],
          ),
        ),
      );

  Widget _offerCard(Map<String, dynamic> offer) => Card(
        child: ListTile(
          title: const Text('New ride request'),
          subtitle: Text('Offer expires at ' + offer['expires_at'].toString()),
          trailing: PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (action) => _run(() async {
              await _invoke(action, {'offerId': offer['id'].toString()});
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'accept_offer', child: Text('Accept')),
              PopupMenuItem(value: 'reject_offer', child: Text('Reject')),
            ],
          ),
        ),
      );

  Widget _chainOfferCard(Map<String, dynamic> offer) => Card(
        child: ListTile(
          leading: const Icon(Icons.alt_route),
          title: const Text('Potential next ride'),
          subtitle: Text('Near your current destination · expires ' + offer['expires_at'].toString()),
          trailing: PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (action) => _run(() async {
              await _invoke(action, {'chainOfferId': offer['id'].toString()});
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'preaccept_chain', child: Text('Pre-accept')),
              PopupMenuItem(value: 'reject_chain', child: Text('Reject')),
            ],
          ),
        ),
      );

  Future<void> _openEmergencyDialer(String rideId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Emergency assistance'),
        content: const Text(
          'For an immediate emergency in India, call 112. '
          'Quick-Ride will try to record an SOS event for this assigned ride, '
          'then open your phone dialer. You must confirm the call in the dialer. '
          'Quick-Ride is not an emergency dispatch service.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open 112 dialer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var recorded = false;
    try {
      await _invoke('safety_event', {'rideId': rideId})
          .timeout(const Duration(seconds: 3));
      recorded = true;
    } catch (_) {
      // Public emergency access must not depend on platform connectivity.
    }
    var dialerOpened = false;
    try {
      dialerOpened = await launchUrl(Uri(scheme: 'tel', path: '112'));
    } catch (_) {
      dialerOpened = false;
    }
    if (!mounted) return;
    final message = !dialerOpened
        ? 'Could not open the phone dialer. Please dial 112 manually.'
        : recorded
            ? 'SOS event recorded. Confirm the emergency call in your phone dialer.'
            : 'Emergency dialer opened. SOS could not be recorded; confirm the call in your phone dialer.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _activeRideCard(Map<String, dynamic> ride) {
    final id = ride['id'].toString();
    final status = ride['status'].toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ride ' + id, style: Theme.of(context).textTheme.titleMedium),
            Text('Status: ' + status.replaceAll('_', ' ')),
            if (ride['pickup_address'] != null) Text('Pickup: ' + ride['pickup_address'].toString()),
            if (ride['destination_address'] != null) Text('Destination: ' + ride['destination_address'].toString()),
            const SizedBox(height: 8),
            if (status == 'accepted' || status == 'driver_arriving')
              FilledButton.icon(
                onPressed: _busy ? null : () => context.push('/ride/$id/navigation'),
                icon: const Icon(Icons.navigation_rounded),
                label: Text(status == 'in_progress' ? 'Navigate to destination' : 'Navigate to pickup'),
              ),
            if (status == 'accepted')
              FilledButton(
                onPressed: _busy ? null : () => _transition('arriving', id),
                child: const Text('I am on the way'),
              ),
            if (status == 'driver_arriving')
              FilledButton(
                onPressed: _busy ? null : () => _transition('arrived', id),
                child: const Text('I have arrived'),
              ),
            if (status == 'arrived') ...[
              TextField(
                controller: _otp,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'Customer pickup OTP', counterText: ''),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _transition('start', id),
                child: const Text('Start trip'),
              ),
            ],
            if (status == 'in_progress') ...[
              FilledButton.icon(
                onPressed: _busy ? null : () => context.push('/ride/$id/navigation'),
                icon: const Icon(Icons.navigation_rounded),
                label: const Text('Navigate to destination'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _transition('complete', id),
                child: const Text('Complete trip'),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _openEmergencyDialer(id),
              icon: const Icon(Icons.call_rounded),
              label: const Text('Emergency · Call 112'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
            if (['accepted', 'driver_arriving', 'arrived'].contains(status))
              TextButton(
                onPressed: _busy ? null : () => _transition('cancel', id),
                child: const Text('Cancel ride'),
              ),
          ],
        ),
      ),
    );
  }
}
