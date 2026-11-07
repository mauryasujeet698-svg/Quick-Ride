import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_customer/src/home_screen.dart';

void main() {
  testWidgets('customer can explore service before signing in', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomerHomeScreen()));
    expect(find.text('Your ride, on your time'), findsOneWidget);
    expect(find.text('Where are you going?'), findsOneWidget);
    expect(find.text('Check service in your area'), findsOneWidget);
    expect(find.text('Book a ride'), findsOneWidget);
  });
}
