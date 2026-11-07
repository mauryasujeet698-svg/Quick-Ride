class QuickRideEnvironment {
  const QuickRideEnvironment({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.mapboxPublicToken,
  });

  factory QuickRideEnvironment.fromBuildDefines() {
    return const QuickRideEnvironment(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
      mapboxPublicToken: String.fromEnvironment('MAPBOX_PUBLIC_TOKEN'),
    );
  }

  final String supabaseUrl;
  final String supabaseAnonKey;
  final String mapboxPublicToken;

  bool get supabaseConfigured =>
      supabaseUrl.startsWith('https://') && supabaseAnonKey.isNotEmpty;
  bool get mapboxConfigured => mapboxPublicToken.isNotEmpty;
}
