import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_admin/src/admin_home_screen.dart';

void main() {
  testWidgets('Admin can explore all read-only tabs before login',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminHomeScreen()));

    expect(find.text('Quick-Ride Admin'), findsOneWidget);
    expect(find.text('Platform overview'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Captains'), findsOneWidget);
    expect(find.text('Rides'), findsOneWidget);
    expect(find.text('Setup'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    await tester.tap(find.text('Captains'));
    await tester.pumpAndSettle();
    expect(find.text('Captain operations'), findsOneWidget);

    await tester.tap(find.text('Rides'));
    await tester.pumpAndSettle();
    expect(find.text('Ride operations'), findsOneWidget);

    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    expect(find.text('Platform configuration'), findsOneWidget);
    await tester.tap(find.text('Service areas and pincodes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Preview mode is read-only'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('More controls'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Sign in to manage Quick-Ride'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sign in to manage Quick-Ride'), findsOneWidget);
    expect(
      find.text('Supabase URL and anon key are required at build time.'),
      findsNothing,
    );
  });
}
