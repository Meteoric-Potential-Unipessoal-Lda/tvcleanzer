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
            AMBIENT = "ambient", INPUTS_POS = "inputsPos", FAV_COLS = "favCols", PHOTO_SEC = "photoSec", HOME_PHOTOS = "homePhotos", FRAME_MUSIC = "frameMusic", PHOTO_REV = "photoRev",
            PREV_DREAM = "prevDream", AUTOSTART = "autostart", SPLASH = "splash", APPS_BELOW = "appsBelow", HERO_TITLE = "heroTitle", MEM_PILL = "memPill", STOCK_OFF = "stockOff", KEY_FILTER = "keyFilter", VOL_SMOOTH = "volSmooth", FAV_BOTTOM = "favBottom", SHELF = "shelf",
            ORDER = "order", AUTOSTART_BOOT = "autostartBoot", ICONS = "icons",
            STYLE = "style", CLOCK_POS = "clockPos", CLOCK_SIZE = "clockSize", CLOCK_FONT = "clockFont",
            W_CITY = "weatherCity", W_LAT = "weatherLat", W_LON = "weatherLon",
            W_TEMP = "weatherTemp", W_CODE = "weatherCode", W_TS = "weatherTs", W_ERR = "weatherErr";

    /** Home screen look: tiles (clock on top, rows of apps), a big clock with a dock, or
     *  «Витрина»: the chosen app's colours fill the screen, big icons in a row below. */
    static final int STYLE_TILES = 0, STYLE_CLOCK = 1, STYLE_SHOWCASE = 2;
    /** App pictures: banners in wide tiles and icons in square ones / icons everywhere / banners. */
    static final int ICONS_AUTO = 0, ICONS_ON = 1, ICONS_BANNERS = 2, ICONS_SMALL = 3;
    /** Theme changes by itself (review request): off, every hour, every day. */
    static final int SKIN_AUTO_OFF = 0, SKIN_AUTO_HOUR = 1, SKIN_AUTO_DAY = 2;
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
    /** 0.89: no frame round the selected app at all — it only grows (an owner's request). */
    boolean ringOff()        { return sp.getBoolean("ringOff", false); }
    void setRingOff(boolean v) { sp.edit().putBoolean("ringOff", v).apply(); }
    /** 0.92 «Свечение»: a soft halo in the app's own colour instead of a frame. */
    boolean ringGlow()       { return sp.getBoolean("ringGlow", false); }
    void setRingGlow(boolean v) { sp.edit().putBoolean("ringGlow", v).apply(); }
    /** «Точка» (1.23, an owner's picture): a small blue dot beside the selected app, no frame. */
    boolean ringDot()        { return sp.getBoolean("ringDot", false); }
    void setRingDot(boolean v) { sp.edit().putBoolean("ringDot", v).apply(); }
    /** 0.99: «ОЗУ 1,1 / 1,7 ГБ» beside the memory icon while it is selected (owners: it covers the city). */
    boolean memLabel()       { return sp.getBoolean("memLabel", true); }
    void setMemLabel(boolean v) { sp.edit().putBoolean("memLabel", v).apply(); }
    /** 1.22: the clock, the date and the weather on the home screen; off leaves only the icons
     *  (an owner: «вообще не было надписей, только иконки приложений»). */
    boolean showClock()      { return sp.getBoolean("showClock", true); }
    /** 1.40: the phone's remote over Wi-Fi (LanRemote), on unless switched off on the TV. */
    boolean lanRemote()      { return sp.getBoolean("lanRemote", true); }
    void setLanRemote(boolean v) { sp.edit().putBoolean("lanRemote", v).apply(); }
    /** 1.38: the weather block's day and date bold (UMID) or thin (small TVs blur bold text). */
    boolean dateBold()       { return sp.getBoolean("dateBold", true); }
    /** 1.46 «Дополнительно» (all off by default): the Bluetooth remote's charge next to its icon,
     *  the «Сейчас играет» card, rain / snow / fog over the wallpaper. */
    /** 1.46: ⚙ and ⋯ in the clock home's dock; off — they sit in the top right corner. */
    boolean dockButtons()    { return sp.getBoolean("dockButtons", true); }
    void setDockButtons(boolean v) { sp.edit().putBoolean("dockButtons", v).apply(); }
    boolean btBattery()      { return sp.getBoolean("btBattery", false); }
    void setBtBattery(boolean v) { sp.edit().putBoolean("btBattery", v).apply(); }
    boolean nowPlaying()     { return sp.getBoolean("nowPlaying", false); }
    void setNowPlaying(boolean v) { sp.edit().putBoolean("nowPlaying", v).apply(); }
    boolean weatherFx()      { return sp.getBoolean("weatherFx", false); }
    void setWeatherFx(boolean v) { sp.edit().putBoolean("weatherFx", v).apply(); }
    /** 1.42: a power button in the top corner (a chat wish: switch off / restart from home). */
    boolean powerIcon()      { return sp.getBoolean("powerIcon", false); }
    void setPowerIcon(boolean v) { sp.edit().putBoolean("powerIcon", v).apply(); }
    /** 1.41: the city's name beside the weather (a chat wish: the weather without it). */
    boolean showCity()       { return sp.getBoolean("showCity", true); }
    void setShowCity(boolean v) { sp.edit().putBoolean("showCity", v).apply(); }
    /** 1.41: the app the corner's VPN icon opens, chosen by the owner ("" = not chosen). */
    String vpnApp()          { return sp.getString("vpnApp", ""); }
    void setVpnApp(String p) { sp.edit().putString("vpnApp", p == null ? "" : p).apply(); }
    void setDateBold(boolean v) { sp.edit().putBoolean("dateBold", v).apply(); }
    void setShowClock(boolean v) { sp.edit().putBoolean("showClock", v).apply(); }
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
    /** «ТВ»: the app the owner chose to show live TV ('' = found by itself, see [Inputs]). */
    String tvApp()           { return sp.getString("tvApp", ""); }
    void setTvApp(String p)  { sp.edit().putString("tvApp", p == null ? "" : p).apply(); }

    List<String> order() {
        String s = sp.getString(ORDER, "");
        return s.isEmpty() ? new ArrayList<String>() : new ArrayList<>(Arrays.asList(s.split(",")));
    }
    void setOrder(List<String> keys) { sp.edit().putString(ORDER, TextUtils.join(",", keys)).apply(); }

    int style()              { return clamp(sp.getInt(STYLE, STYLE_TILES), 0, 2); }
    void setStyle(int v)     { sp.edit().putInt(STYLE, clamp(v, 0, 2)).apply(); }
    int icons()              { return clamp(sp.getInt(ICONS, ICONS_AUTO), 0, 3); }
    void setIcons(int v)     { sp.edit().putInt(ICONS, clamp(v, 0, 3)).apply(); }
    int skinAuto()           { return clamp(sp.getInt("skinAuto", SKIN_AUTO_OFF), 0, 2); }
    void setSkinAuto(int v)  { sp.edit().putInt("skinAuto", clamp(v, 0, 2)).putLong("skinAt", System.currentTimeMillis()).apply(); }
    /** Live background: seconds for one drift (0 = by the animation setting, 14 / 22 s). */
    int ambientSec()         { int v = sp.getInt("ambientSec", 0); return v <= 0 ? 0 : clamp(v, 4, 300); }
    void setAmbientSec(int v) { sp.edit().putInt("ambientSec", v <= 0 ? 0 : clamp(v, 4, 300)).apply(); }

    /** «Кнопки пульта»: remote key code → app package. */
    java.util.Map<Integer, String> keyMap() {
        java.util.Map<Integer, String> m = new java.util.HashMap<>();
        for (String part : sp.getString("keyMap", "").split(";")) {
            int eq = part.indexOf('=');
            if (eq <= 0) continue;
            try { m.put(Integer.parseInt(part.substring(0, eq)), part.substring(eq + 1)); } catch (NumberFormatException ignored) {}
        }
        return m;
    }
    private void saveKeys(java.util.Map<Integer, String> m) {
        StringBuilder b = new StringBuilder();
        for (java.util.Map.Entry<Integer, String> e : m.entrySet()) {
            if (b.length() > 0) b.append(';');
            b.append(e.getKey()).append('=').append(e.getValue());
        }
        sp.edit().putString("keyMap", b.toString()).apply();
    }
    void putKey(int code, String pkg) { java.util.Map<Integer, String> m = keyMap(); m.put(code, pkg); saveKeys(m); }
    void removeKey(int code)          { java.util.Map<Integer, String> m = keyMap(); m.remove(code); saveKeys(m); }

    /** Time for the next theme? Then it moves on to the next one and says true. */
    boolean nextSkinIfDue() {
        int mode = skinAuto();
        if (mode == SKIN_AUTO_OFF) return false;
        long at = sp.getLong("skinAt", 0), now = System.currentTimeMillis();
        long period = mode == SKIN_AUTO_HOUR ? 3600_000L : 24 * 3600_000L;
        if (at > 0 && now - at < period) return false;
        Skin cur = skin();
        int i = 0;
        for (int k = 0; k < Skin.ALL.length; k++) if (Skin.ALL[k].id.equals(cur.id)) i = k;
        sp.edit().putString(SKIN, Skin.ALL[(i + 1) % Skin.ALL.length].id).putLong("skinAt", now).apply();
        return at > 0; // the very first check only starts the clock
    }
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
    /** Music in the photo frame (when there are tracks); on unless the owner turned it off. */
    boolean frameMusic()     { return sp.getBoolean(FRAME_MUSIC, true); }
    /** «Живые обои» (0.61+): the phone's video behind the home screen, when there is one. */
    boolean liveWallOn()     { return sp.getBoolean("liveWallOn", true); }
    void setLiveWallOn(boolean v) { sp.edit().putBoolean("liveWallOn", v).apply(); }
    /** 1.05: the clip's own sound on the home screen (an owner: a fireplace without its crackle). */
    boolean liveSound()      { return sp.getBoolean("liveSound", false); }
    void setLiveSound(boolean v) { sp.edit().putBoolean("liveSound", v).apply(); }
    void setFrameMusic(boolean v) { sp.edit().putBoolean(FRAME_MUSIC, v).apply(); }
    /** Loading screen with the logo while the launcher starts. */
    boolean splash()         { return sp.getBoolean(SPLASH, true); }
    void setSplash(boolean v) { sp.edit().putBoolean(SPLASH, v).apply(); }
    /** Tiles style: the app grid starts on the second screen (only favourites on the first). */
    boolean appsBelow()      { return sp.getBoolean(APPS_BELOW, false); }
    /** «Витрина»: the focused app's name in large letters above the tiles (0.33+). */
    boolean heroTitle()      { return sp.getBoolean(HERO_TITLE, true); }
    /** Top bar (0.61+): the greeting line, the clock size (0 large, 1 medium, 2 small), date and
     *  weather on one line beside the clock. */
    boolean greeting()       { return sp.getBoolean("greeting", true); }
    void setGreeting(boolean v) { sp.edit().putBoolean("greeting", v).apply(); }
    int barClock()           { return clamp(sp.getInt("barClock", 0), 0, 2); }
    void setBarClock(int v)  { sp.edit().putInt("barClock", clamp(v, 0, 2)).apply(); }
    boolean oneLine()        { return sp.getBoolean("oneLine", false); }
    void setOneLine(boolean v) { sp.edit().putBoolean("oneLine", v).apply(); }
    void setHeroTitle(boolean v) { sp.edit().putBoolean(HERO_TITLE, v).apply(); }
    /** RAM pill on the home screen; pressing it closes background apps (0.36+). */
    boolean memPill()        { return sp.getBoolean(MEM_PILL, true); }
    /** Only the gear up top, and it opens the TV's own settings (hold: the launcher's). A review
     *  asked for the cleanest look: no network pill, no «Настройки ТВ» pill. */
    boolean cleanBar()       { return sp.getBoolean("cleanBar", false); }
    void setCleanBar(boolean v) { sp.edit().putBoolean("cleanBar", v).apply(); }
    void setMemPill(boolean v) { sp.edit().putBoolean(MEM_PILL, v).apply(); }
    /** Bluetooth pill in the top bar (0.63). */
    boolean btPill()         { return sp.getBoolean("btPill", true); }
    void setBtPill(boolean v) { sp.edit().putBoolean("btPill", v).apply(); }
    /** Top bar as round icons instead of words (network icon in a status colour) — owners
     *  who like it minimal asked for it (0.55+). */
    boolean barIcons()       { return sp.getBoolean("barIcons", false); }
    void setBarIcons(boolean v) { sp.edit().putBoolean("barIcons", v).apply(); }
    static final int BAR_WORDS = 0, BAR_ICONS = 1, BAR_MINI = 2;
    /** Top bar: words, round icons (0.55) or small icons in the screen's corner like a tablet's
     *  status bar (0.68, the default for everyone — owners asked for it «срочно»). */
    int barStyle()           { return clamp(sp.getInt("barStyle", BAR_MINI), 0, 2); }
    void setBarStyle(int v)  { sp.edit().putInt("barStyle", clamp(v, 0, 2)).apply(); }
    static final int FAV_FULL = 0, FAV_START = 1, FAV_CENTER = 2;
    /** «Рамка избранного» (one row of favourites, tiles home): as wide as its tiles on the left
     *  (default) or in the middle, or the whole width as before 0.68. */
    int favAlign()           { return clamp(sp.getInt("favAlign", FAV_START), 0, 2); }
    void setFavAlign(int v)  { sp.edit().putInt("favAlign", clamp(v, 0, 2)).apply(); }
    /** Glass under the clock, date and weather (0.68, off by default). */
    boolean clockGlass()     { return sp.getBoolean("clockGlass", false); }
    /** No names under the home screen's icons (0.83, an owner: the dock gets lower); the
     *  all-apps grid keeps them. */
    boolean noLabels()       { return sp.getBoolean("noLabels", false); }
    void setNoLabels(boolean v) { sp.edit().putBoolean("noLabels", v).apply(); }
    void setClockGlass(boolean v) { sp.edit().putBoolean("clockGlass", v).apply(); }
    /** «Избранное» / «Приложения» headings over the rows (0.55+). */
    boolean sectionTitles()  { return sp.getBoolean("sectionTitles", true); }
    void setSectionTitles(boolean v) { sp.edit().putBoolean("sectionTitles", v).apply(); }
    static final int SHAPE_ROUNDED = 0, SHAPE_CIRCLE = 1;
    /** App icons in «Иконки» / «Маленькие значки»: rounded squares or circles (0.55+). */
    int iconShape()          { return clamp(sp.getInt("iconShape", SHAPE_ROUNDED), 0, 1); }
    void setIconShape(int v) { sp.edit().putInt("iconShape", clamp(v, 0, 1)).apply(); }
    static final int NIGHT_OFF = 0, NIGHT_ON = 1, NIGHT_SCHEDULE = 2;
    /** Night mode: a warm, dimmer screen over everything (drawn by the Home-key service). */
    int nightMode()          { return clamp(sp.getInt("nightMode", NIGHT_OFF), 0, 2); }
    void setNightMode(int v) { sp.edit().putInt("nightMode", clamp(v, 0, 2)).apply(); }
    /** Strength 1–5. */
    int nightLevel()         { return clamp(sp.getInt("nightLevel", 3), 1, 5); }
    void setNightLevel(int v) { sp.edit().putInt("nightLevel", clamp(v, 1, 5)).apply(); }
    /** Schedule, minutes after midnight: from (default 20:00) to (default 07:00). */
    int nightFrom()          { return clamp(sp.getInt("nightFrom", 20 * 60), 0, 24 * 60 - 1); }
    int nightTo()            { return clamp(sp.getInt("nightTo", 7 * 60), 0, 24 * 60 - 1); }
    void setNightFrom(int m) { sp.edit().putInt("nightFrom", clamp(m, 0, 24 * 60 - 1)).apply(); }
    void setNightTo(int m)   { sp.edit().putInt("nightTo", clamp(m, 0, 24 * 60 - 1)).apply(); }
    /** Night mode should be showing now. */
    boolean nightNow() {
        int m = nightMode();
        if (m == NIGHT_ON) return true;
        if (m != NIGHT_SCHEDULE) return false;
        java.util.Calendar c = java.util.Calendar.getInstance();
        int now = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE);
        int from = nightFrom(), to = nightTo();
        return from <= to ? now >= from && now < to : now >= from || now < to;
    }
    void setAppsBelow(boolean v) { sp.edit().putBoolean(APPS_BELOW, v).apply(); }
    /** With appsBelow: favourites sit at the bottom of the first screen, over the photo. */
    boolean favBottom()      { return sp.getBoolean(FAV_BOTTOM, false); }
    void setFavBottom(boolean v) { sp.edit().putBoolean(FAV_BOTTOM, v).apply(); }
    /** Every glass on the home screen (0.72: favourites, the dock, under the clock, the corner
     *  icons; before only the favourites): 0 light glass (default), 1 transparent, 2 dark. */
    static final int SHELF_GLASS = 0, SHELF_CLEAR = 1, SHELF_DARK = 2, SHELF_FROST = 3; // 3: 1.54 «Матовое»
    int shelf()              { return clamp(sp.getInt(SHELF, SHELF_GLASS), 0, 3); }
    void setShelf(int v)     { sp.edit().putInt(SHELF, clamp(v, 0, 3)).apply(); }
    /** The TV's own home (Google TV) was switched off by TVCleanzer to keep this launcher. */
    boolean stockOff()       { return sp.getBoolean(STOCK_OFF, false); }
    void setStockOff(boolean v) { sp.edit().putBoolean(STOCK_OFF, v).apply(); }
    /** False when the phone app found that Home opens us by itself: the service then stops
     *  catching keys (that cost owners key repeat: Volume held moved one step). */
    boolean keyFilter()      { return sp.getBoolean(KEY_FILTER, true); }
    void setKeyFilter(boolean v) { sp.edit().putBoolean(KEY_FILTER, v).apply(); }
    /** «Громкость при зажатии → Меняется плавно»: the owner's word, above what the phone app and
     *  the Google TV keys would like. The key filter is what costs key repeat (held Volume moves
     *  one step); without it Home still lands on us, the service replaces the stock screen by its
     *  window. Not chosen yet: HomeKeyService.volumeFiltered decides by the TV. */
    boolean volSmoothSet()   { return sp.contains(VOL_SMOOTH); }
    /** The Home-key service has run and the owner has not switched it off since (BootReceiver
     *  puts it back after a reboot only then). */
    boolean serviceWanted()  { return sp.getBoolean("serviceWanted", false); }
    void setServiceWanted(boolean v) { sp.edit().putBoolean("serviceWanted", v).apply(); }
    boolean volSmooth()      { return sp.getBoolean(VOL_SMOOTH, false); }
    void setVolSmooth(boolean v) { sp.edit().putBoolean(VOL_SMOOTH, v).apply(); }
    static boolean xiaomi() {
        String m = android.os.Build.MANUFACTURER;
        return m != null && m.toLowerCase(java.util.Locale.ROOT).contains("xiaomi");
    }
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
