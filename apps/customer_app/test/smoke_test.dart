import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_customer/src/home_screen.dart';

void main() {
  testWidgets('customer can explore the Mapbox homepage before signing in',
      (tester) async {
    QuickRideMaps.mapWidgetOverride = (_, __) => const ColoredBox(
          key: ValueKey('mapbox-test-map'),
          color: Colors.transparent,
        );
    addTearDown(() {
      QuickRideMaps.mapWidgetOverride = null;
    });

    await tester.pumpWidget(const MaterialApp(home: CustomerHomeScreen()));
    await tester.pump();

    expect(find.text('Quick Ride'), findsOneWidget);
    expect(find.text('PICKUP'), findsOneWidget);
    expect(find.text('Where would you like to go?'), findsOneWidget);
    expect(find.text('Set pickup'), findsOneWidget);
    expect(find.text('Set destination'), findsOneWidget);
    expect(find.byKey(const ValueKey('mapbox-test-map')), findsOneWidget);
    expect(find.text('Choose ride'), findsOneWidget);
  });
}
