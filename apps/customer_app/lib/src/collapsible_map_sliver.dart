import 'package:flutter/material.dart';

/// A pinned map sliver that reduces its height by 80% as the page scrolls.
/// Keep map gestures inside [child]; the page content below remains the
/// primary scroll surface.
class CollapsibleMapSliver extends StatelessWidget {
  const CollapsibleMapSliver({
    super.key,
    required this.child,
    this.expandedHeightFactor = 0.43,
    this.collapsedHeightFactor = 0.20,
  }) : assert(expandedHeightFactor > 0),
       assert(collapsedHeightFactor > 0 && collapsedHeightFactor <= 1);

  final Widget child;
  final double expandedHeightFactor;
  final double collapsedHeightFactor;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = screenHeight * expandedHeightFactor;
    final minHeight = maxHeight * collapsedHeightFactor;
    return SliverPersistentHeader(
      pinned: true,
      delegate: _CollapsibleMapHeaderDelegate(
        child: child,
        minHeight: minHeight,
        maxHeight: maxHeight,
      ),
    );
  }
}

class _CollapsibleMapHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _CollapsibleMapHeaderDelegate({
    required this.child,
    required this.minHeight,
    required this.maxHeight,
  });

  final Widget child;
  final double minHeight;
  final double maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => maxHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ClipRect(child: SizedBox.expand(child: child));
  }

  @override
  bool shouldRebuild(covariant _CollapsibleMapHeaderDelegate oldDelegate) =>
      oldDelegate.child != child ||
      oldDelegate.minHeight != minHeight ||
      oldDelegate.maxHeight != maxHeight;
}
