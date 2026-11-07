import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_admin/src/admin_home_screen.dart';

void main() {
  testWidgets('admin can explore the read-only preview before backend setup', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminHomeScreen()));

    expect(find.text('Quick-Ride Admin'), findsOneWidget);
    expect(find.text('Platform control centre'), findsOneWidget);
    expect(find.textContaining('Preview mode · Read only'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Service areas and pincodes'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Service areas and pincodes'), findsOneWidget);
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
