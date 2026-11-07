class QuickRideEnvironment {
  const QuickRideEnvironment({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  factory QuickRideEnvironment.fromBuildDefines() {
    return const QuickRideEnvironment(
      supabaseUrl: String.fromEnvironment(
        'SUPABASE_URL',
        defaultValue: 'https://czbelhtemzklcmssumpc.supabase.co',
      ),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
        defaultValue: 'sb_publishable_0es_pudIg1ghhsSciZL_Sw_LGaiO7zh',
      ),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;

  bool get supabaseConfigured =>
      supabaseUrl.startsWith('https://') && supabasePublishableKey.isNotEmpty;
}
