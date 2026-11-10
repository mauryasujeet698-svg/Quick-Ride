import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('captain can explore the read-only preview before backend setup',
      (tester) async {
    QuickRideMaps.mapWidgetOverride = (_, __) => const ColoredBox(
          key: ValueKey('captain-map-test-placeholder'),
          color: Colors.transparent,
        );
    addTearDown(() {
      QuickRideMaps.mapWidgetOverride = null;
    });

    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));
    await tester.pump();

    expect(find.text('Quick Ride Captain'), findsOneWidget);
    expect(find.text('Driver partner'), findsOneWidget);
    expect(find.textContaining('Preview mode · Read only'), findsOneWidget);
    expect(find.byKey(const ValueKey('captain-map-test-placeholder')), findsOneWidget);
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
