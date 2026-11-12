import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';


class CustomerServicesScreen extends StatelessWidget {
  const CustomerServicesScreen({super.key});

  void _openRide(BuildContext context, String categoryCode) {
    context.push('/book', extra: {'vehicleCategoryCode': categoryCode});
  }

  void _showParcelNotice(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Parcel booking is being prepared. Ride services are available now.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final services = <({
      String title,
      String description,
      IconData icon,
      String? categoryCode,
      bool comingSoon,
    })>[
      (
        title: 'Parcel',
        description: 'Send packages across your service area',
        icon: Icons.inventory_2_outlined,
        categoryCode: null,
        comingSoon: true,
      ),
      (
        title: 'Car',
        description: 'Comfortable everyday rides',
        icon: Icons.directions_car_filled_outlined,
        categoryCode: 'mini',
        comingSoon: false,
      ),
      (
        title: 'Auto',
        description: 'Affordable local travel',
        icon: Icons.electric_rickshaw,
        categoryCode: 'auto',
        comingSoon: false,
      ),
      (
        title: 'Bike',
        description: 'Quick rides through the city',
        icon: Icons.two_wheeler,
        categoryCode: 'bike',
        comingSoon: false,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('All Services')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'Choose how you want to travel',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Available ride options depend on your pickup location.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 18),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: services.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.03,
            ),
            itemBuilder: (context, index) {
              final service = services[index];
              return Material(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: () {
                    if (service.comingSoon) {
                      _showParcelNotice(context);
                    } else {
                      _openRide(context, service.categoryCode!);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(17),
                          ),
                          child: Icon(
                            service.icon,
                            size: 30,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                service.title,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                            ),
                            if (service.comingSoon)
                              const Icon(Icons.schedule_rounded, size: 17),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          service.comingSoon ? 'Coming soon' : service.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
