import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Holds the four customer destinations in GoRouter's indexed stack.
/// Inactive branches stay mounted, preserving the Home map and scroll state.
class CustomerTabShell extends StatelessWidget {
  const CustomerTabShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: navigationShell,
        bottomNavigationBar: CustomerNavigationBar(
          navigationShell: navigationShell,
        ),
      );
}

class CustomerNavigationBar extends StatelessWidget {
  const CustomerNavigationBar({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _items = <({IconData icon, IconData selectedIcon, String label})>[
    (icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.route_outlined, selectedIcon: Icons.route_rounded, label: 'My Rides'),
    (icon: Icons.grid_view_outlined, selectedIcon: Icons.grid_view_rounded, label: 'All Services'),
    (icon: Icons.person_outline_rounded, selectedIcon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final selectedIndex = navigationShell.currentIndex;
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(16, 5, 16, safeBottom > 0 ? 3 : 7),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: List.generate(_items.length, (index) {
            final item = _items[index];
            final selected = selectedIndex == index;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Semantics(
                  button: true,
                  selected: selected,
                  label: item.label,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(21),
                    onTap: () => navigationShell.goBranch(
                      index,
                      initialLocation: index == selectedIndex,
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      constraints: const BoxConstraints(minHeight: 49),
                      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(21),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected ? item.selectedIcon : item.icon,
                            size: 21,
                            color: selected
                                ? colors.onPrimaryContainer
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9.5,
                              height: 1.05,
                              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                              color: selected
                                  ? colors.onPrimaryContainer
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
