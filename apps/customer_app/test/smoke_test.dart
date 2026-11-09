import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_customer/src/home_screen.dart';

void main() {
  testWidgets('customer can explore the booking homepage before signing in',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomerHomeScreen()));
    await tester.pump();

    expect(find.text('Quick Ride'), findsOneWidget);
    expect(find.text('PICKUP'), findsOneWidget);
    expect(find.text('Where would you like to go?').first, findsOneWidget);
    expect(find.text('Set pickup'), findsOneWidget);
    expect(find.text('Set destination'), findsOneWidget);
    expect(find.text('Choose ride'), findsOneWidget);
  });
}
