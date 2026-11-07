import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('driver screen displays backend state without configuration', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));
    expect(find.text('Quick-Ride backend is not configured.'), findsOneWidget);
  });
}
