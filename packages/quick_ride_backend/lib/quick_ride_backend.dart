import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class QuickRideBackend {
  QuickRideBackend._();

  static SupabaseClient? _client;
  static bool get isInitialized => _client != null;

  static SupabaseClient get client {
    final value = _client;
    if (value == null) {
      throw StateError('Quick-Ride backend is not configured.');
    }
    return value;
  }

  static Future<bool> initialize(QuickRideEnvironment environment) async {
    if (_client != null) return true;
    if (!environment.supabaseConfigured) return false;
    await Supabase.initialize(
      url: environment.supabaseUrl,
      anonKey: environment.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    _client = Supabase.instance.client;
    return true;
  }

  static Future<FunctionResponse> invoke(
    String functionName, {
    required Map<String, dynamic> body,
  }) {
    return client.functions.invoke(functionName, body: body);
  }
}
