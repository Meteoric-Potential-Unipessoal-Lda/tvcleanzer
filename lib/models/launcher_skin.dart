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
        bgTop: Color(0xFF070B14), bgBottom: Color(0xFF101A2E),
        accent: Color(0xFF00CFA8), tile: Color(0xFF1A2335)),
    LauncherSkin(id: 'aurora', name: tr('Аврора'),
        bgTop: Color(0xFF0A0C1A), bgBottom: Color(0xFF221A47),
        accent: Color(0xFFA78BFA), tile: Color(0xFF2A2547)),
    LauncherSkin(id: 'sunset', name: tr('Закат'),
        bgTop: Color(0xFF120A10), bgBottom: Color(0xFF3D1A10),
        accent: Color(0xFFFB923C), tile: Color(0xFF3A1F1A)),
    LauncherSkin(id: 'ocean', name: tr('Океан'),
        bgTop: Color(0xFF061019), bgBottom: Color(0xFF0A3346),
        accent: Color(0xFF22D3EE), tile: Color(0xFF123447)),
    LauncherSkin(id: 'graphite', name: tr('Графит'),
        bgTop: Color(0xFF0A0A0A), bgBottom: Color(0xFF1E1E1E),
        accent: Color(0xFFE5E5E5), tile: Color(0xFF2B2B2B)),
    LauncherSkin(id: 'forest', name: tr('Лес'),
        bgTop: Color(0xFF07120C), bgBottom: Color(0xFF0E2E1B),
        accent: Color(0xFF4ADE80), tile: Color(0xFF1A3324)),
  ];

  static LauncherSkin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
