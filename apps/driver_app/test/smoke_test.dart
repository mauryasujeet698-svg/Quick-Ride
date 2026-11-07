import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('driver sign-in screen is shown when signed out', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
