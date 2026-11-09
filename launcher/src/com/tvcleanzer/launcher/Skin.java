package com.tvcleanzer.launcher;

/** Colour themes. Ids and colours match the phone app (LauncherSkin). */
final class Skin {
    final String id, name;
    final int bgTop, bgBottom, accent, tile;

    private Skin(String id, String name, int bgTop, int bgBottom, int accent, int tile) {
        this.id = id; this.name = name;
        this.bgTop = bgTop; this.bgBottom = bgBottom; this.accent = accent; this.tile = tile;
    }

    static final Skin[] ALL = {
        new Skin("midnight", "Полночь",  0xFF0B1120, 0xFF16233B, 0xFF00CFA8, 0xFF1E293B),
        new Skin("aurora",   "Аврора",   0xFF0F172A, 0xFF3B2A7A, 0xFFA78BFA, 0xFF2E2A5C),
        new Skin("sunset",   "Закат",    0xFF1F1022, 0xFF7C2D12, 0xFFFB923C, 0xFF4A1E1A),
        new Skin("ocean",    "Океан",    0xFF0C1E2E, 0xFF0E7490, 0xFF22D3EE, 0xFF12405A),
        new Skin("graphite", "Графит",   0xFF111111, 0xFF2A2A2A, 0xFFE5E5E5, 0xFF333333),
        new Skin("forest",   "Лес",      0xFF0B1F14, 0xFF14532D, 0xFF4ADE80, 0xFF1C3B28),
    };

    static Skin byId(String id) {
        for (Skin s : ALL) if (s.id.equals(id)) return s;
        return ALL[0];
    }

    Skin next() {
        for (int i = 0; i < ALL.length; i++) if (ALL[i] == this) return ALL[(i + 1) % ALL.length];
        return ALL[0];
    }
}
