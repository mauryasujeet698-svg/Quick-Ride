import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('Captain can explore all read-only tabs before backend setup',
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
    expect(find.text('Captain dashboard'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Rides'), findsOneWidget);
    expect(find.text('Earnings'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.byKey(const ValueKey('captain-map-test-placeholder')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Trip navigation'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Trip navigation'), findsOneWidget);

    await tester.tap(find.text('Rides'));
    await tester.pumpAndSettle();
    expect(find.text('Ride management'), findsOneWidget);
    expect(find.text('Accept · Preview'), findsOneWidget);

    await tester.tap(find.text('Earnings'));
    await tester.pumpAndSettle();
    expect(find.text('Earnings & settlements'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Captain account'), findsOneWidget);
    expect(find.text('Sign in to activate Captain features'), findsOneWidget);
    expect(find.text('Quick-Ride backend is not configured.'), findsNothing);
  });
}
