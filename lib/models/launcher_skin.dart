import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
/// A colour theme for the TVCleanzer Launcher on the TV.
class LauncherSkin {
  final String id;
  final String name;
  final Color bgTop;
  final Color bgBottom;
  final Color accent;
  final Color tile;

  const LauncherSkin({
    required this.id,
    required this.name,
    required this.bgTop,
    required this.bgBottom,
    required this.accent,
    required this.tile,
  });

  static final all = <LauncherSkin>[
    LauncherSkin(id: 'midnight', name: tr('Полночь'),
        bgTop: const Color(0xFF070B14), bgBottom: const Color(0xFF101A2E),
        accent: const Color(0xFF00CFA8), tile: const Color(0xFF1A2335)),
    LauncherSkin(id: 'aurora', name: tr('Аврора'),
        bgTop: const Color(0xFF0A0C1A), bgBottom: const Color(0xFF221A47),
        accent: const Color(0xFFA78BFA), tile: const Color(0xFF2A2547)),
    LauncherSkin(id: 'sunset', name: tr('Закат'),
        bgTop: const Color(0xFF120A10), bgBottom: const Color(0xFF3D1A10),
        accent: const Color(0xFFFB923C), tile: const Color(0xFF3A1F1A)),
    LauncherSkin(id: 'ocean', name: tr('Океан'),
        bgTop: const Color(0xFF061019), bgBottom: const Color(0xFF0A3346),
        accent: const Color(0xFF22D3EE), tile: const Color(0xFF123447)),
    LauncherSkin(id: 'graphite', name: tr('Графит'),
        bgTop: const Color(0xFF0A0A0A), bgBottom: const Color(0xFF1E1E1E),
        accent: const Color(0xFFE5E5E5), tile: const Color(0xFF2B2B2B)),
    LauncherSkin(id: 'forest', name: tr('Лес'),
        bgTop: const Color(0xFF07120C), bgBottom: const Color(0xFF0E2E1B),
        accent: const Color(0xFF4ADE80), tile: const Color(0xFF1A3324)),
    LauncherSkin(id: 'ruby', name: tr('Рубин'),
        bgTop: const Color(0xFF12070A), bgBottom: const Color(0xFF3A0E1C),
        accent: const Color(0xFFF43F5E), tile: const Color(0xFF3A1622)),
    LauncherSkin(id: 'gold', name: tr('Золото'),
        bgTop: const Color(0xFF100D07), bgBottom: const Color(0xFF2E2410),
        accent: const Color(0xFFFACC15), tile: const Color(0xFF33291A)),
    LauncherSkin(id: 'arctic', name: tr('Арктика'),
        bgTop: const Color(0xFF0B1220), bgBottom: const Color(0xFF1E3A5F),
        accent: const Color(0xFF93C5FD), tile: const Color(0xFF22344F)),
    LauncherSkin(id: 'neon', name: tr('Неон'),
        bgTop: const Color(0xFF0D0716), bgBottom: const Color(0xFF2A0F3D),
        accent: const Color(0xFFF472B6), tile: const Color(0xFF311A44)),
  ];

  static LauncherSkin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
