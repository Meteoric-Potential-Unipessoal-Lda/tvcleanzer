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
            AMBIENT = "ambient", INPUTS_POS = "inputsPos", FAV_COLS = "favCols", PHOTO_SEC = "photoSec", HOME_PHOTOS = "homePhotos", PHOTO_REV = "photoRev",
            PREV_DREAM = "prevDream", AUTOSTART = "autostart", SPLASH = "splash", APPS_BELOW = "appsBelow", HERO_TITLE = "heroTitle", STOCK_OFF = "stockOff", KEY_FILTER = "keyFilter", FAV_BOTTOM = "favBottom", SHELF = "shelf",
            ORDER = "order", AUTOSTART_BOOT = "autostartBoot", ICONS = "icons",
            STYLE = "style", CLOCK_POS = "clockPos", CLOCK_SIZE = "clockSize", CLOCK_FONT = "clockFont",
            W_CITY = "weatherCity", W_LAT = "weatherLat", W_LON = "weatherLon",
            W_TEMP = "weatherTemp", W_CODE = "weatherCode", W_TS = "weatherTs", W_ERR = "weatherErr";

    /** Home screen look: tiles (clock on top, rows of apps), a big clock with a dock, or
     *  «Витрина»: the chosen app's colours fill the screen, big icons in a row below. */
    static final int STYLE_TILES = 0, STYLE_CLOCK = 1, STYLE_SHOWCASE = 2;
    /** App pictures: banners in wide tiles and icons in square ones / icons everywhere / banners. */
    static final int ICONS_AUTO = 0, ICONS_ON = 1, ICONS_BANNERS = 2;
    static final int CLOCK_LEFT = 0, CLOCK_CENTER = 1;
    /** System font families for the clock: thin, light, regular, condensed, bold. */
    static final String[] CLOCK_FONTS = {"sans-serif-thin", "sans-serif-light", "sans-serif",
            "sans-serif-condensed", "sans-serif-medium"};
    static final String[] CLOCK_FONT_NAMES = {T.t("Тонкий"), T.t("Лёгкий"), T.t("Обычный"), T.t("Узкий"), T.t("Жирный")};

    /** Where the HDMI/tuner row goes: above favourites, under all apps, or nowhere. */
    static final int INPUTS_TOP = 0, INPUTS_BOTTOM = 1, INPUTS_HIDDEN = 2;

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
    int inputsPos()          { return clamp(sp.getInt(INPUTS_POS, INPUTS_TOP), 0, 2); }
    void setInputsPos(int v) { sp.edit().putInt(INPUTS_POS, clamp(v, 0, 2)).apply(); }
    /** Favourites: 0 = one scrolling row, 4/5/6 = a grid with that many per row (several rows). */
    int favCols()            { int v = sp.getInt(FAV_COLS, 0); return v == 4 || v == 5 || v == 6 ? v : 0; }
    void setFavCols(int v)   { sp.edit().putInt(FAV_COLS, v == 4 || v == 5 || v == 6 ? v : 0).apply(); }
    /** App opened when the TV is switched on ("" = just this home screen). */
    String autostart()       { return sp.getString(AUTOSTART, ""); }
    void setAutostart(String pkg) { sp.edit().putString(AUTOSTART, pkg == null ? "" : pkg).apply(); }
    int autostartBoot()      { return sp.getInt(AUTOSTART_BOOT, -1); }
    void setAutostartBoot(int boot) { sp.edit().putInt(AUTOSTART_BOOT, boot).apply(); }
    /** Own order of the "Apps" grid (packages; the rest follow alphabetically). */
    List<String> order() {
        String s = sp.getString(ORDER, "");
        return s.isEmpty() ? new ArrayList<String>() : new ArrayList<>(Arrays.asList(s.split(",")));
    }
    void setOrder(List<String> keys) { sp.edit().putString(ORDER, TextUtils.join(",", keys)).apply(); }

    int style()              { return clamp(sp.getInt(STYLE, STYLE_TILES), 0, 2); }
    void setStyle(int v)     { sp.edit().putInt(STYLE, clamp(v, 0, 2)).apply(); }
    int icons()              { return clamp(sp.getInt(ICONS, ICONS_AUTO), 0, 2); }
    void setIcons(int v)     { sp.edit().putInt(ICONS, clamp(v, 0, 2)).apply(); }
    int clockPos()           { return clamp(sp.getInt(CLOCK_POS, CLOCK_CENTER), 0, 1); }
    void setClockPos(int v)  { sp.edit().putInt(CLOCK_POS, clamp(v, 0, 1)).apply(); }
    /** Clock size, percent of the standard size (60–180). */
    int clockSize()          { return clamp(sp.getInt(CLOCK_SIZE, 100), 60, 180); }
    void setClockSize(int v) { sp.edit().putInt(CLOCK_SIZE, clamp(v, 60, 180)).apply(); }
    int clockFont()          { return clamp(sp.getInt(CLOCK_FONT, 0), 0, CLOCK_FONTS.length - 1); }
    void setClockFont(int v) { sp.edit().putInt(CLOCK_FONT, clamp(v, 0, CLOCK_FONTS.length - 1)).apply(); }

    boolean hasWeather()     { return !weatherCity().isEmpty(); }
    String weatherCity()     { return sp.getString(W_CITY, ""); }
    float weatherLat()       { return sp.getFloat(W_LAT, 0f); }
    float weatherLon()       { return sp.getFloat(W_LON, 0f); }
    int weatherTemp()        { return sp.getInt(W_TEMP, 0); }
    int weatherCode()        { return sp.getInt(W_CODE, 0); }
    long weatherTs()         { return sp.getLong(W_TS, 0); }
    /** Last failed fetch ("" = fine): shown in Settings and sent to the phone app. */
    String weatherError()    { return sp.getString(W_ERR, ""); }
    void setWeatherError(String e) { sp.edit().putString(W_ERR, e == null ? "" : e).apply(); }
    /** A new city (or "" to switch weather off); the old reading is dropped. */
    void setWeatherPlace(String city, float lat, float lon) {
        sp.edit().putString(W_CITY, city == null ? "" : city).putFloat(W_LAT, lat).putFloat(W_LON, lon)
                .putLong(W_TS, 0).remove(W_ERR).apply();
    }
    void setWeatherNow(int temp, int code) {
        sp.edit().putInt(W_TEMP, temp).putInt(W_CODE, code).putLong(W_TS, System.currentTimeMillis())
                .remove(W_ERR).apply();
    }

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
    /** Photo frame: seconds per photo (10 s … 10 min). */
    int photoSec()           { return clamp(sp.getInt(PHOTO_SEC, 30), 10, 600); }
    void setPhotoSec(int v)  { sp.edit().putInt(PHOTO_SEC, clamp(v, 10, 600)).apply(); }
    /** The home background changes through the photos too (off by default). */
    boolean homePhotos()     { return sp.getBoolean(HOME_PHOTOS, false); }
    /** Loading screen with the logo while the launcher starts. */
    boolean splash()         { return sp.getBoolean(SPLASH, true); }
    void setSplash(boolean v) { sp.edit().putBoolean(SPLASH, v).apply(); }
    /** Tiles style: the app grid starts on the second screen (only favourites on the first). */
    boolean appsBelow()      { return sp.getBoolean(APPS_BELOW, false); }
    /** «Витрина»: the focused app's name in large letters above the tiles (0.33+). */
    boolean heroTitle()      { return sp.getBoolean(HERO_TITLE, true); }
    void setHeroTitle(boolean v) { sp.edit().putBoolean(HERO_TITLE, v).apply(); }
    void setAppsBelow(boolean v) { sp.edit().putBoolean(APPS_BELOW, v).apply(); }
    /** With appsBelow: favourites sit at the bottom of the first screen, over the photo. */
    boolean favBottom()      { return sp.getBoolean(FAV_BOTTOM, false); }
    void setFavBottom(boolean v) { sp.edit().putBoolean(FAV_BOTTOM, v).apply(); }
    /** Favourites shelf: 0 glass (default), 1 transparent, 2 dark. */
    static final int SHELF_GLASS = 0, SHELF_CLEAR = 1, SHELF_DARK = 2;
    int shelf()              { return clamp(sp.getInt(SHELF, SHELF_GLASS), 0, 2); }
    void setShelf(int v)     { sp.edit().putInt(SHELF, clamp(v, 0, 2)).apply(); }
    /** The TV's own home (Google TV) was switched off by TVCleanzer to keep this launcher. */
    boolean stockOff()       { return sp.getBoolean(STOCK_OFF, false); }
    void setStockOff(boolean v) { sp.edit().putBoolean(STOCK_OFF, v).apply(); }
    /** False when the phone app found that Home opens us by itself: the service then stops
     *  catching keys (that cost owners key repeat: Volume held moved one step). */
    boolean keyFilter()      { return sp.getBoolean(KEY_FILTER, true); }
    void setKeyFilter(boolean v) { sp.edit().putBoolean(KEY_FILTER, v).apply(); }
    void setHomePhotos(boolean v) { sp.edit().putBoolean(HOME_PHOTOS, v).apply(); }
    long photoRev()          { return sp.getLong(PHOTO_REV, 0); }
    void bumpPhotos()        { sp.edit().putLong(PHOTO_REV, System.currentTimeMillis()).apply(); }
    /** The screensaver the TV had before the photo frame (to give it back). */
    String prevDream()       { return sp.getString(PREV_DREAM, ""); }
    void setPrevDream(String v) { sp.edit().putString(PREV_DREAM, v == null ? "" : v).apply(); }
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
