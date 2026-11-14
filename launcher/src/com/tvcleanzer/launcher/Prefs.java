package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** All launcher settings. One SharedPreferences file, read in-process. */
final class Prefs {
    static final String FILE = "launcher";
    static final String SKIN = "skin", CLOCK24 = "clock24", LABELS = "labels",
            FAVORITES = "favorites", HIDDEN = "hidden",
            WALL_REV = "wallpaperRev", KIDS = "kids", KIDS_APPS = "kidsApps", PIN = "pinHash",
            ANIM = "anim", RING_ACCENT = "ringAccent", TILES = "tileSize", WALL_DIM = "wallDim",
            AMBIENT = "ambient";

    /** Animation level: full, soft (smaller and slower), off (instant, for weak TVs). */
    static final int ANIM_FULL = 0, ANIM_SOFT = 1, ANIM_OFF = 2;
    /** Tile size: compact (7 per row), normal (6), large (5). */
    static final int TILES_COMPACT = 0, TILES_NORMAL = 1, TILES_LARGE = 2;

    final SharedPreferences sp;

    Prefs(Context c) { sp = c.getSharedPreferences(FILE, Context.MODE_PRIVATE); }

    Skin skin()              { return Skin.byId(sp.getString(SKIN, "midnight")); }
    void setSkin(Skin s)     { sp.edit().putString(SKIN, s.id).apply(); }
    boolean clock24()        { return sp.getBoolean(CLOCK24, true); }
    void setClock24(boolean v) { sp.edit().putBoolean(CLOCK24, v).apply(); }
    /** true: names always under tiles; false: only for the focused tile (like tvOS). */
    boolean labelsAlways()   { return sp.getBoolean(LABELS, false); }
    void setLabelsAlways(boolean v) { sp.edit().putBoolean(LABELS, v).apply(); }

    int anim()               { return clamp(sp.getInt(ANIM, ANIM_FULL), 0, 2); }
    void setAnim(int v)      { sp.edit().putInt(ANIM, clamp(v, 0, 2)).apply(); }
    /** Focus ring in the skin's accent colour instead of white. */
    boolean ringAccent()     { return sp.getBoolean(RING_ACCENT, false); }
    void setRingAccent(boolean v) { sp.edit().putBoolean(RING_ACCENT, v).apply(); }
    int tileSize()           { return clamp(sp.getInt(TILES, TILES_NORMAL), 0, 2); }
    void setTileSize(int v)  { sp.edit().putInt(TILES, clamp(v, 0, 2)).apply(); }
    /** How much the own photo is darkened, percent (0–90). */
    int wallDim()            { return clamp(sp.getInt(WALL_DIM, 40), 0, 90); }
    void setWallDim(int v)   { sp.edit().putInt(WALL_DIM, clamp(v, 0, 90)).apply(); }
    /** Slowly drifting accent glow behind the home screen (skins without a photo). */
    boolean ambient()        { return sp.getBoolean(AMBIENT, true); }
    void setAmbient(boolean v) { sp.edit().putBoolean(AMBIENT, v).apply(); }

    private static int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }

    boolean hasFavorites()   { return sp.contains(FAVORITES); }
    List<String> favorites() {
        String raw = sp.getString(FAVORITES, "");
        List<String> out = new ArrayList<>();
        if (!TextUtils.isEmpty(raw)) out.addAll(Arrays.asList(raw.split(",")));
        return out;
    }
    void setFavorites(List<String> keys) {
        sp.edit().putString(FAVORITES, TextUtils.join(",", keys)).apply();
    }
    void resetFavorites()    { sp.edit().remove(FAVORITES).apply(); }

    long wallpaperRev()      { return sp.getLong(WALL_REV, 0); }
    void bumpWallpaper()     { sp.edit().putLong(WALL_REV, System.currentTimeMillis()).apply(); }

    boolean kids()           { return sp.getBoolean(KIDS, false); }
    void setKids(boolean v)  { sp.edit().putBoolean(KIDS, v).apply(); }
    Set<String> kidsApps()   { return new HashSet<>(sp.getStringSet(KIDS_APPS, new HashSet<String>())); }
    void setKidsApps(Set<String> keys) { sp.edit().putStringSet(KIDS_APPS, new HashSet<>(keys)).apply(); }

    boolean hasPin()         { return sp.contains(PIN); }
    void setPin(String pin)  { sp.edit().putString(PIN, hash(pin)).apply(); }
    boolean checkPin(String pin) { return hasPin() && hash(pin).equals(sp.getString(PIN, "")); }

    private static String hash(String pin) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(("tvcleanzer:" + pin).getBytes("UTF-8"));
            StringBuilder b = new StringBuilder();
            for (byte x : h) b.append(String.format("%02x", x));
            return b.toString();
        } catch (Exception e) {
            return pin;
        }
    }

    Set<String> hidden()     { return new HashSet<>(sp.getStringSet(HIDDEN, new HashSet<String>())); }
    void setHidden(Set<String> keys) { sp.edit().putStringSet(HIDDEN, new HashSet<>(keys)).apply(); }
}
