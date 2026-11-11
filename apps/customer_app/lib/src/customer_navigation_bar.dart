import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class CustomerNavigationBar extends StatelessWidget {
  const CustomerNavigationBar({super.key, required this.selectedIndex});

  final int selectedIndex;

  static const _routes = ['/', '/my-rides', '/services', '/profile'];
  static const _items = <({IconData icon, IconData selectedIcon, String label})>[
    (icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.route_outlined, selectedIcon: Icons.route_rounded, label: 'My Rides'),
    (icon: Icons.grid_view_outlined, selectedIcon: Icons.grid_view_rounded, label: 'All Services'),
    (icon: Icons.person_outline_rounded, selectedIcon: Icons.person_rounded, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(16, 8, 16, safeBottom > 0 ? 4 : 10),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF17251E),
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 6),
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
                    borderRadius: BorderRadius.circular(26),
                    onTap: () {
                      if (!selected) context.go(_routes[index]);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 190),
                      curve: Curves.easeOutCubic,
                      constraints: const BoxConstraints(minHeight: 72),
                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 3),
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFF315D48) : Colors.transparent,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected ? item.selectedIcon : item.icon,
                            size: 27,
                            color: selected
                                ? const Color(0xFFE2F5E9)
                                : const Color(0xFFC2CEC7),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.1,
                              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                              color: selected
                                  ? const Color(0xFFE2F5E9)
                                  : const Color(0xFFC2CEC7),
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
