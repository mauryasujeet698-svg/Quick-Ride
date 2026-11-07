import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('driver can explore the read-only preview before backend setup', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));

    expect(find.text('Quick-Ride Driver'), findsOneWidget);
    expect(find.text('Driver partner'), findsOneWidget);
    expect(find.textContaining('Preview mode · Read only'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Trip navigation'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Trip navigation'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Sign in to activate driver features'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sign in to activate driver features'), findsOneWidget);
    expect(find.text('Quick-Ride backend is not configured.'), findsNothing);
  });
}
