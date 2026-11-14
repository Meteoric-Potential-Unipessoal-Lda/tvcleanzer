import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'launcher_screen.dart';
import 'remote_screen.dart';

import '../l10n/l10n.dart';
class _Tab {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _Tab(this.icon, this.activeIcon, this.label);
}

final _tabs = [
  _Tab(Icons.cleaning_services_outlined, Icons.cleaning_services_rounded, tr('Очистка')),
  _Tab(Icons.dashboard_customize_outlined, Icons.dashboard_customize_rounded, tr('Лаунчер')),
  _Tab(Icons.history_rounded, Icons.history_rounded, tr('История')),
  _Tab(Icons.settings_remote_outlined, Icons.settings_remote_rounded, tr('Пульт')),
];

/// Main screen with the four tabs and the animated bottom menu.
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _pages = <Widget>[
    HomeScreen(),
    LauncherScreen(),
    HistoryScreen(),
    RemoteScreen(),
  ];

  void _select(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(fit: StackFit.expand, children: [
        // All tabs stay alive; only the active one is visible and ticking.
        for (var i = 0; i < _pages.length; i++)
          // The fade itself must keep ticking, so TickerMode wraps only the
          // page: otherwise a tab that is being hidden freezes fully visible.
          IgnorePointer(
            ignoring: i != _index,
            child: AnimatedOpacity(
              opacity: i == _index ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              child: AnimatedSlide(
                offset: i == _index ? Offset.zero : const Offset(0, .015),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: TickerMode(enabled: i == _index, child: _pages[i]),
              ),
            ),
          ),
      ]),
      bottomNavigationBar: _AnimatedNavBar(index: _index, onTap: _select),
    );
  }
}

class _AnimatedNavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _AnimatedNavBar({required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        height: 68,
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.cardBd),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
          ],
        ),
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth / _tabs.length;
          return Stack(children: [
            // Sliding highlight under the active tab
            AnimatedPositioned(
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutBack,
              left: index * w + 6,
              top: 8,
              bottom: 8,
              width: w - 12,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.accentDim,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.accent.withValues(alpha: .25)),
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < _tabs.length; i++)
                Expanded(child: _NavItem(
                  tab: _tabs[i],
                  active: i == index,
                  onTap: () => onTap(i),
                )),
            ]),
          ]);
        }),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final _Tab tab;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({required this.tab, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.fgMid;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        AnimatedScale(
          scale: active ? 1.15 : 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(active ? tab.activeIcon : tab.icon,
                key: ValueKey(active), color: color, size: 24),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
          child: Text(tab.label),
        ),
      ]),
    );
  }
}
