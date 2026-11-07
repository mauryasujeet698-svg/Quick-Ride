import 'dart:async';
import 'dart:math';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  List<Map<String, dynamic>> _categories = [];
  int? _categoryId;
  StreamSubscription<dynamic>? _locationSubscription;
  StreamSubscription<dynamic>? _authSubscription;
  DateTime _lastLocationSent = DateTime.fromMillisecondsSinceEpoch(0);
  String? _message;
  List<Map<String, dynamic>> _documents = [];
  bool _loadingDocuments = false;
  String? _uploadingDocumentType;

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
        } else {
          _loadCategories();
          _loadDocuments();
        }
      });
      if (QuickRideAuth.currentUser != null) {
        _loadCategories();
        _loadDocuments();
      }
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
    if (!RegExp(r'^[1-9][0-9]{5}  Future<void> _setOnline(bool online) async {
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

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (!QuickRideBackend.isInitialized) {
      return const Scaffold(
        body: Center(child: Text('Quick-Ride backend is not configured.')),
      );
    }
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick-Ride Driver')),
        body: Center(
          child: FilledButton.icon(
            onPressed: () => QuickRideAuth.signInWithGoogle(
              redirectTo: 'in.quickride.driver://login-callback',
            ),
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google'),
          ),
        ),
      );
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

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _availabilityCard(),
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
            if (status == 'in_progress')
              FilledButton(
                onPressed: _busy ? null : () => _transition('complete', id),
                child: const Text('Complete trip'),
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
).hasMatch(pin)) {
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
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
        allowMultiple: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The selected file could not be read. Please choose it again.');
      }
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Each document must be 5 MB or smaller.');
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
            const Text('Upload a clear PDF, JPG or PNG for each item. Maximum 5 MB per file. Admin approval is required before you can go online.'),
            if (_loadingDocuments) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            ...requiredDocuments.entries.map((entry) {
              final matches = _documents.where(
                (document) => document['document_type'] == entry.key,
              ).toList();
              final latest = matches.isEmpty ? null : matches.first;
              final status = latest?['verification_status']?.toString() ?? 'not_uploaded';
              final isApproved = status == 'approved';
              final isUploading = _uploadingDocumentType == entry.key;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isApproved ? Icons.verified_rounded : Icons.description_outlined,
                  color: isApproved ? Colors.green : null,
                ),
                title: Text(entry.value),
                subtitle: Text(
                  status == 'not_uploaded'
                      ? 'Not uploaded'
                      : status.replaceAll('_', ' '),
                ),
                trailing: isApproved
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : isUploading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
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

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    if (!QuickRideBackend.isInitialized) {
      return const Scaffold(
        body: Center(child: Text('Quick-Ride backend is not configured.')),
      );
    }
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick-Ride Driver')),
        body: Center(
          child: FilledButton.icon(
            onPressed: () => QuickRideAuth.signInWithGoogle(
              redirectTo: 'in.quickride.driver://login-callback',
            ),
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google'),
          ),
        ),
      );
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

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _availabilityCard(),
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
          const Text('Admin verification and service-pincode approval are required before going online.'),
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
            if (status == 'in_progress')
              FilledButton(
                onPressed: _busy ? null : () => _transition('complete', id),
                child: const Text('Complete trip'),
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
