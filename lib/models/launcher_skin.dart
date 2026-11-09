import 'package:flutter/material.dart';

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

  static const all = <LauncherSkin>[
    LauncherSkin(id: 'midnight', name: 'Полночь',
        bgTop: Color(0xFF0B1120), bgBottom: Color(0xFF16233B),
        accent: Color(0xFF00CFA8), tile: Color(0xFF1E293B)),
    LauncherSkin(id: 'aurora', name: 'Аврора',
        bgTop: Color(0xFF0F172A), bgBottom: Color(0xFF3B2A7A),
        accent: Color(0xFFA78BFA), tile: Color(0xFF2E2A5C)),
    LauncherSkin(id: 'sunset', name: 'Закат',
        bgTop: Color(0xFF1F1022), bgBottom: Color(0xFF7C2D12),
        accent: Color(0xFFFB923C), tile: Color(0xFF4A1E1A)),
    LauncherSkin(id: 'ocean', name: 'Океан',
        bgTop: Color(0xFF0C1E2E), bgBottom: Color(0xFF0E7490),
        accent: Color(0xFF22D3EE), tile: Color(0xFF12405A)),
    LauncherSkin(id: 'graphite', name: 'Графит',
        bgTop: Color(0xFF111111), bgBottom: Color(0xFF2A2A2A),
        accent: Color(0xFFE5E5E5), tile: Color(0xFF333333)),
    LauncherSkin(id: 'forest', name: 'Лес',
        bgTop: Color(0xFF0B1F14), bgBottom: Color(0xFF14532D),
        accent: Color(0xFF4ADE80), tile: Color(0xFF1C3B28)),
  ];

  static LauncherSkin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.first);
}
