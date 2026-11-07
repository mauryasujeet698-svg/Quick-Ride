import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_admin/src/admin_home_screen.dart';

void main() {
  testWidgets('admin requires backend configuration before use', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminHomeScreen()));
    expect(find.text('Supabase URL and anon key are required at build time.'), findsOneWidget);
  });
}
