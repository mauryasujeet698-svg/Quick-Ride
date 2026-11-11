import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('Captain can explore all read-only tabs before backend setup',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));
    await tester.pump();

    expect(find.text('Quick Ride Captain'), findsOneWidget);
    expect(find.text('Captain dashboard'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Rides'), findsOneWidget);
    expect(find.text('Earnings'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.textContaining('Allow location access to centre your Captain map.'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Trip navigation'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Trip navigation'), findsOneWidget);

    final captainNavigation = find.byType(NavigationBar);
    tester.widget<NavigationBar>(captainNavigation)
        .onDestinationSelected!(1);
    await tester.pump();
    expect(tester.widget<NavigationBar>(captainNavigation).selectedIndex, 1);
    expect(find.text('Ride management'), findsOneWidget);
    expect(find.text('Accept · Preview'), findsOneWidget);

    tester.widget<NavigationBar>(find.byType(NavigationBar))
        .onDestinationSelected!(2);
    await tester.pumpAndSettle();
    expect(find.text('Earnings & settlements'), findsOneWidget);

    tester.widget<NavigationBar>(find.byType(NavigationBar))
        .onDestinationSelected!(3);
    await tester.pumpAndSettle();
    expect(find.text('Captain account'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Sign in to activate Captain features'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sign in to activate Captain features'), findsOneWidget);
    expect(find.text('Quick-Ride backend is not configured.'), findsNothing);
  });
}
