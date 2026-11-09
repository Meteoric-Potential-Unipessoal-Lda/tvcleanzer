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
        new Skin("midnight", "Полночь",  0xFF070B14, 0xFF101A2E, 0xFF00CFA8, 0xFF1A2335),
        new Skin("aurora",   "Аврора",   0xFF0A0C1A, 0xFF221A47, 0xFFA78BFA, 0xFF2A2547),
        new Skin("sunset",   "Закат",    0xFF120A10, 0xFF3D1A10, 0xFFFB923C, 0xFF3A1F1A),
        new Skin("ocean",    "Океан",    0xFF061019, 0xFF0A3346, 0xFF22D3EE, 0xFF123447),
        new Skin("graphite", "Графит",   0xFF0A0A0A, 0xFF1E1E1E, 0xFFE5E5E5, 0xFF2B2B2B),
        new Skin("forest",   "Лес",      0xFF07120C, 0xFF0E2E1B, 0xFF4ADE80, 0xFF1A3324),
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
