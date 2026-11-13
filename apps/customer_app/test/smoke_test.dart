import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_customer/src/home_screen.dart';

void main() {
  testWidgets('customer can explore compact booking home before signing in',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomerHomeScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Quick Ride'), findsNothing);
    expect(find.byType(CustomerHomeScreen), findsOneWidget);
    expect(find.text('Pickup'), findsOneWidget);
    expect(find.text('Destination'), findsNothing);
    expect(find.text('Enter destination'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Search by voice'), findsOneWidget);
    expect(find.text('View ride options'), findsNothing);
    expect(find.textContaining('Sign in'), findsNothing);
  });
}
