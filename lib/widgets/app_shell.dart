import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'common.dart';

/// A dashboard "shell": a [PageView] of top-level tab bodies with a bottom
/// nav bar wired to it. Tapping a tab (or swiping) animates the page in with
/// a slide transition instead of pushing a whole new route — this is used
/// for the Home / Activity / Wallet / Profile group on the passenger side,
/// the Home / Trips / Earnings / Profile group on the rider side, and the
/// equivalent group in Vehicle Owner mode.
///
/// Anything *inside* a tab that needs its own history (viewing a single
/// wallet top-up sheet's transaction, opening "Ride History", drilling into
/// "Earnings" from Profile, etc.) still uses normal `Navigator.push` — this
/// shell only replaces the outer 4-tab navigation.
class AppShell extends StatefulWidget {
  final List<SbNavItem> items;
  final List<Widget> pages;
  final int initialIndex;

  const AppShell({
    super.key,
    required this.items,
    required this.pages,
    this.initialIndex = 0,
  }) : assert(items.length == pages.length);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  void _goTo(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _controller.animateToPage(
      i,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _controller,
        onPageChanged: (i) => setState(() => _index = i),
        children: widget.pages,
      ),
      bottomNavigationBar: SbBottomNav(
        activeIndex: _index,
        items: widget.items,
        onTap: _goTo,
      ),
    );
  }
}

/// Small header used at the top of an embedded tab body in place of a full
/// AppBar (no back button — tabs are siblings, not a navigation stack).
class SbTabHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const SbTabHeader({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
          Row(children: actions),
        ],
      ),
    );
  }
}

/// A little animated dot used to signal "online"/"live" states.
class SbPulseDot extends StatefulWidget {
  final Color color;
  final double size;
  const SbPulseDot({super.key, this.color = AppColors.secondary, this.size = 8});

  @override
  State<SbPulseDot> createState() => _SbPulseDotState();
}

class _SbPulseDotState extends State<SbPulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: widget.size + (widget.size * 3 * t),
              height: widget.size + (widget.size * 3 * t),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: (1 - t) * 0.35),
              ),
            ),
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
            ),
          ],
        );
      },
    );
  }
}
