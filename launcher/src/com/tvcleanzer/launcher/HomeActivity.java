package com.tvcleanzer.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextClock;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The home screen: clock, favourites row, all apps grid. */
public class HomeActivity extends Activity implements SharedPreferences.OnSharedPreferenceChangeListener {

    private static final String[] DEFAULT_FAVORITES = {
            "com.google.android.youtube.tv", "com.netflix.ninja", "ru.kinopoisk",
            "ru.ivi.client", "com.spotify.tv.android", "org.videolan.vlc",
            "com.plexapp.android", "com.android.vending", "com.android.tv.settings",
    };
    /** Per tile size (Prefs.TILES_*): apps per row and favourites visible at once. */
    private static final int[] GRID_COLUMNS = {7, 6, 5};
    private static final int[] FAV_VISIBLE = {5, 4, 3};

    private Prefs prefs;
    private PackageManager pm;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Map<String, Drawable> artCache = new HashMap<>();
    private final Map<String, Boolean> bannerCache = new HashMap<>();
    private List<AppEntry> apps = new ArrayList<>();
    /** The "Apps" grid as shown (own order first), for moving tiles left/right. */
    private List<AppEntry> gridOrder = new ArrayList<>();
    private List<AppEntry> favorites = new ArrayList<>();
    private final Set<String> homeApps = new java.util.HashSet<>();
    private List<Inputs.Item> inputs = new ArrayList<>();
    private android.graphics.Bitmap wallBitmap;
    private String wallKey = "";
    private android.widget.ImageView wallView;
    private int homePhotoIdx;

    private FrameLayout root;
    /** Holds [root] and, on top while the launcher starts, the loading screen. */
    private FrameLayout frame;
    private SplashView splash;
    private boolean appsLoaded, wallPending;
    private ScrollView scroll;
    private View favTitle, favShelf;   // the favourites block of the tiles home (null without one)
    private boolean focusHooked;
    private boolean resumed, dirty;
    private boolean entered;                       // entrance animation played
    /** Clock style: the full app grid is open ("All apps"); Back or Home returns to the clock. */
    private boolean showGrid;
    private TextView weatherView;
    private final List<View> ambientGlows = new ArrayList<>();
    private android.animation.ValueAnimator ambientAnim;

    private final BroadcastReceiver packages = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            String pkg = i.getData() != null ? i.getData().getSchemeSpecificPart() : null;
            if (pkg != null) {
                artCache.remove(pkg);
                bannerCache.remove(pkg);
            }
            reloadApps();
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        pm = getPackageManager();
        root = new FrameLayout(this);
        root.setClipChildren(false);
        root.setBackground(Ui.background(prefs.skin()));
        frame = new FrameLayout(this);
        frame.addView(root, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        if (prefs.splash()) {
            splash = new SplashView(this, prefs.skin());
            frame.addView(splash, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            main.postDelayed(hideSplash, 7000);     // never stay longer than this
        }
        setContentView(frame);

        prefs.sp.registerOnSharedPreferenceChangeListener(this);
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addDataScheme("package");
        registerReceiver(packages, f);
        // after a reboot Wi-Fi comes up after the home screen: keep the pill (and weather) current
        try { registerReceiver(netChanged, new IntentFilter("android.net.conn.CONNECTIVITY_CHANGE")); } catch (Exception ignored) {}
        reloadApps();
    }

    @Override
    protected void onDestroy() {
        prefs.sp.unregisterOnSharedPreferenceChangeListener(this);
        try { unregisterReceiver(packages); } catch (Exception ignored) {}
        try { unregisterReceiver(netChanged); } catch (Exception ignored) {}
        io.shutdownNow();
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        if (dirty) { dirty = false; build(); } else startAmbient();
        maybeAutostart();
        main.removeCallbacks(weatherTick);
        main.post(weatherTick);
        main.removeCallbacks(homePhotoTick);
        main.postDelayed(homePhotoTick, Math.max(30, prefs.photoSec()) * 1000L);
    }

    /** The home screen is drawn (apps listed, photo decoded): let the loading screen go,
     *  after it has been up for at least a moment so it doesn't just flash. */
    private void maybeHideSplash() {
        if (splash == null || splash.leaving() || !appsLoaded || wallPending) return;
        main.removeCallbacks(hideSplash);
        main.postDelayed(hideSplash, Math.max(0, 1600 - splash.age()));
    }

    private final Runnable hideSplash = new Runnable() {
        @Override public void run() {
            final SplashView s = splash;
            if (s == null || s.leaving()) return;
            main.removeCallbacks(this);
            s.dismiss(() -> {
                frame.removeView(s);
                if (splash == s) splash = null;
                View f = getCurrentFocus();
                if (f == null) root.requestFocus();
            });
        }
    };

    /** Home background through the photo-frame photos, one every photoSec (at least 30 s). */
    private final Runnable homePhotoTick = new Runnable() {
        @Override public void run() {
            if (!resumed) return;
            long every = Math.max(30, prefs.photoSec()) * 1000L;
            final List<java.io.File> list = prefs.homePhotos() && !prefs.kids() ? Photos.list(HomeActivity.this)
                    : new ArrayList<java.io.File>();
            if (list.size() > 1 && wallView != null) {
                homePhotoIdx = (homePhotoIdx + 1) % list.size();
                final java.io.File f = list.get(homePhotoIdx);
                io.execute(() -> {
                    final android.graphics.Bitmap b = Photos.load(HomeActivity.this, f);
                    main.post(() -> {
                        final android.widget.ImageView v = wallView;
                        if (b == null || v == null) return;
                        wallBitmap = b;
                        // frame-by-frame, like the photo frame: View animations follow the TV's
                        // animation scale (often 0) and the photos would just "click"
                        fade(v, 1f, 0f, 700, () -> {
                            v.setImageBitmap(b);
                            fade(v, 0f, 1f, 900, null);
                        });
                    });
                });
            }
            main.postDelayed(this, every);
        }
    };

    private void fade(final View v, final float from, final float to, final long ms, final Runnable end) {
        final long start = android.os.SystemClock.uptimeMillis();
        main.post(new Runnable() {
            @Override public void run() {
                float t = Math.min(1f, (android.os.SystemClock.uptimeMillis() - start) / (float) ms);
                float e = t * t * (3f - 2f * t);
                v.setAlpha(from + (to - from) * e);
                if (t < 1f) main.postDelayed(this, 16);
                else if (end != null) end.run();
            }
        });
    }

    /** The home screen can stay open for hours: re-check the weather every 10 minutes while visible. */
    private final Runnable weatherTick = new Runnable() {
        @Override public void run() {
            refreshWeather();
            // No reading yet (new city, network not up after boot): try again in a minute.
            long next = prefs.hasWeather() && prefs.weatherTs() == 0 ? 60 * 1000L : 10 * 60 * 1000L;
            if (resumed) main.postDelayed(this, next);
        }
    };

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (showGrid) { showGrid = false; build(); }
    }

    private void refreshWeather() {
        if (!prefs.hasWeather()) return;
        io.execute(() -> {
            if (Weather.refreshIfStale(prefs)) main.post(this::updateWeatherView);
        });
    }

    private void updateWeatherView() {
        if (weatherView == null) return;
        String w = Weather.line(prefs);
        weatherView.setText(w == null ? "" : w);
        weatherView.setVisibility(w == null ? View.GONE : View.VISIBLE);
    }

    private TextClock bigClock(float sizeSp) {
        TextClock clock = new TextClock(this);
        String fmt = prefs.clock24() ? "HH:mm" : "h:mm";
        clock.setFormat24Hour(fmt);
        clock.setFormat12Hour(fmt);
        clock.setTextSize(sizeSp * prefs.clockSize() / 100f);
        clock.setTextColor(0xFFFFFFFF);
        clock.setIncludeFontPadding(false);
        clock.setSingleLine(true);
        clock.setLetterSpacing(-0.02f);
        clock.setShadowLayer(Ui.dp(this, 12), 0, Ui.dp(this, 2), 0x66000000);
        clock.setTypeface(android.graphics.Typeface.create(Prefs.CLOCK_FONTS[prefs.clockFont()],
                android.graphics.Typeface.NORMAL));
        return clock;
    }

    private TextClock dateLine(String fmt) {
        TextClock t = new TextClock(this);
        t.setFormat12Hour(fmt);
        t.setFormat24Hour(fmt);
        t.setAllCaps(true);
        t.setLetterSpacing(0.12f);
        t.setTextSize(15);
        t.setTextColor(0xB3FFFFFF);
        t.setSingleLine(true);
        t.setEllipsize(null);
        t.setIncludeFontPadding(false);
        // the last letter's spacing is not counted in the measured width: give it room
        t.setPadding(0, 0, Ui.dp(this, 6), 0);
        return t;
    }

    /** Big clock never wider than the screen or taller than a third of it ("Огромные" on 720p TVs). */
    private static void fitClock(TextClock c, int maxW, int maxH) {
        android.graphics.Paint p = new android.graphics.Paint(c.getPaint());
        float size = c.getTextSize();
        p.setTextSize(size);
        float w = p.measureText("88:88");
        android.graphics.Paint.FontMetrics fm = p.getFontMetrics();
        float h = fm.descent - fm.ascent;
        float k = Math.min(1f, Math.min(maxW / Math.max(1f, w), maxH / Math.max(1f, h)));
        if (k < 1f) c.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, size * k * 0.97f);
    }

    /** Clock style: date, a big clock and the weather in the middle; a glass dock below. */
    private void buildClockHome(Skin skin, int screenW, int padH, int padV, int anim, int ringColor, String focusPkg) {
        boolean center = prefs.clockPos() == Prefs.CLOCK_CENTER;
        LinearLayout mid = new LinearLayout(this);
        mid.setOrientation(LinearLayout.VERTICAL);
        mid.setGravity(center ? Gravity.CENTER_HORIZONTAL : Gravity.START);
        int textGravity = center ? Gravity.CENTER_HORIZONTAL : Gravity.START;
        int screenH = getResources().getDisplayMetrics().heightPixels;

        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE, d MMMM");
        date.setFormat24Hour("EEEE, d MMMM");
        date.setTextSize(20);
        date.setTextColor(0xD9FFFFFF);
        date.setShadowLayer(Ui.dp(this, 8), 0, 0, 0x66000000);
        date.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        // Full width, one line: wrap_content clocks were measured before their text arrived on
        // some TVs and showed "2" instead of "20:52" (owners' photos).
        date.setSingleLine(true);
        date.setGravity(textGravity);
        mid.addView(date, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        TextClock big = bigClock(150);
        big.setSingleLine(true);
        big.setGravity(textGravity);
        fitClock(big, screenW - 2 * padH, Math.round(screenH * 0.34f));
        mid.addView(big, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        weatherView = Ui.text(this, 20, 0xD9FFFFFF, "sans-serif-medium");
        weatherView.setShadowLayer(Ui.dp(this, 8), 0, 0, 0x66000000);
        weatherView.setGravity(textGravity);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wlp.topMargin = Ui.dp(this, 6);
        mid.addView(weatherView, wlp);
        updateWeatherView();

        FrameLayout.LayoutParams mlp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP);
        mlp.topMargin = Math.round(screenH * 0.12f);
        mid.setPadding(padH, 0, padH, 0);
        root.addView(mid, mlp);

        // Dock: inputs, favourites (icons), settings, all apps
        favGridCols = 0; // one row in the dock: ▲▼ do not move a favourite here
        LinearLayout dock = row();
        dock.setGravity(Gravity.CENTER_VERTICAL);
        dock.setBackground(Ui.glass(Ui.dp(this, 34)));
        int dp18 = Ui.dp(this, 18);
        dock.setPadding(dp18, dp18, dp18, Ui.dp(this, 8));
        // the tile size setting works here too: compact / normal / large dock icons
        final float[] dockScale = {0.85f, 1f, 1.35f};
        int icon = Math.round(Math.max(Ui.dp(this, 64), Math.round(screenW * 0.05f)) * dockScale[prefs.tileSize()]);
        int gap = Ui.dp(this, 16);
        List<AppTile> tiles = new ArrayList<>();
        List<View> order = new ArrayList<>();

        if (!inputs.isEmpty() && prefs.inputsPos() != Prefs.INPUTS_HIDDEN) {
            Pill in = new Pill(this, T.t("Источник"));
            in.setOnClickListener(v -> chooseInput());
            order.add(in);
        }
        GearButton gear = new GearButton(this, skin.accent);
        gear.setOnClickListener(v -> startActivity(new Intent(this, SettingsActivity.class)));
        Pill all = new Pill(this, T.t("Все приложения"));
        all.setOnClickListener(v -> { showGrid = true; build(); });

        // The whole dock must fit the screen (a centred dock wider than the screen loses both
        // ends): shrink the icons, then show fewer favourites, if needed.
        int unspecified = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED);
        all.measure(unspecified, unspecified);
        int fixed = 2 * dp18 + all.getMeasuredWidth() + Ui.dp(this, 46) + gap;
        if (!order.isEmpty()) { order.get(0).measure(unspecified, unspecified); fixed += order.get(0).getMeasuredWidth() + gap; }
        int avail = screenW - 2 * padH - fixed;
        int n = Math.min(8, favorites.size());
        while (n > 0 && (avail - gap * n) / n < Ui.dp(this, 44)) n--;
        if (n > 0) icon = Math.min(icon, (avail - gap * n) / n);
        for (int k = 0; k < n; k++) {
            AppTile t = tile(favorites.get(k), icon, icon, skin, false, 12, 1.12f, anim, ringColor);
            tiles.add(t);
            order.add(t);
        }
        order.add(gear);
        order.add(all);

        for (int i = 0; i < order.size(); i++) {
            View v = order.get(i);
            LinearLayout.LayoutParams lp = v instanceof GearButton
                    ? new LinearLayout.LayoutParams(Ui.dp(this, 46), Ui.dp(this, 46))
                    : new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            if (i > 0) lp.leftMargin = gap;
            lp.gravity = Gravity.CENTER_VERTICAL;
            dock.addView(v, lp);
        }
        FrameLayout.LayoutParams dlp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        dlp.bottomMargin = Math.max(padV, Math.round(getResources().getDisplayMetrics().heightPixels * 0.07f));
        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.setClipChildren(false);
        hs.setClipToPadding(false);
        hs.addView(dock);
        root.addView(hs, dlp);

        View target = null;
        for (AppTile t : tiles) if (t.app.pkg.equals(focusPkg)) { target = t; break; }
        if (target == null) target = tiles.isEmpty() ? all : tiles.get(0);
        target.requestFocus();
        if (target instanceof AppTile && ((AppTile) target).app.pkg.equals(movingPkg)) ((AppTile) target).setMoving(true);
        if (!entered) {
            entered = true;
            for (int i = 0; i < tiles.size(); i++) tiles.get(i).enter(i);
        }
        loadArt(tiles);
        if (resumed) startAmbient();
    }

    private void chooseInput() {
        if (inputs.size() == 1) { openInput(inputs.get(0)); return; }
        String[] names = new String[inputs.size()];
        for (int i = 0; i < names.length; i++) names[i] = inputs.get(i).label;
        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("Источник"))
                .setItems(names, (d, which) -> openInput(inputs.get(which)))
                .show();
    }

    private void openInput(Inputs.Item it) {
        try { startActivity(Inputs.intent(it)); }
        catch (Exception e) { Toast.makeText(this, T.f("Не удалось открыть {0}", it.label), Toast.LENGTH_SHORT).show(); }
    }

    /** First Home after a boot: open the app chosen to start with the TV (once per boot). */
    private void maybeAutostart() {
        String pkg = prefs.autostart();
        if (pkg.isEmpty() || prefs.kids() || android.os.SystemClock.elapsedRealtime() > 5 * 60 * 1000L) return;
        int boot = Settings.Global.getInt(getContentResolver(), "boot_count", -1);
        if (boot < 0 || boot == prefs.autostartBoot()) return;
        prefs.setAutostartBoot(boot);
        openAutostart(this, pkg);
    }

    static boolean openAutostart(android.content.Context c, String pkg) {
        android.content.pm.PackageManager pm = c.getPackageManager();
        Intent i = pm.getLeanbackLaunchIntentForPackage(pkg);
        if (i == null) i = pm.getLaunchIntentForPackage(pkg);
        if (i == null) return false;
        try {
            c.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    @Override
    protected void onPause() {
        resumed = false;
        main.removeCallbacks(weatherTick);
        main.removeCallbacks(homePhotoTick);
        stopAmbient();
        super.onPause();
    }

    @Override
    public void onSharedPreferenceChanged(SharedPreferences sp, String key) {
        // Fresh weather or the once-per-boot marker: no need to redraw the whole screen.
        if (key != null && (key.equals(Prefs.W_TEMP) || key.equals(Prefs.W_CODE) || key.equals(Prefs.W_TS)
                || key.equals(Prefs.W_ERR)
                || key.equals(Prefs.AUTOSTART_BOOT))) {
            main.post(this::updateWeatherView);
            return;
        }
        // A new city: fetch its weather right away.
        if (Prefs.W_CITY.equals(key) && resumed) main.post(this::refreshWeather);
        // Settings screen or the phone app changed something.
        if (resumed) main.post(this::build); else dirty = true;
    }

    /** Home must never close itself; Back jumps to the top instead. */
    @Override
    public void onBackPressed() {
        if (showGrid) { showGrid = false; build(); return; }
        if (scroll != null && scroll.getScrollY() > 0) {
            scroll.smoothScrollTo(0, 0);
            focusFirst();
        }
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        // a key while loading: skip the loading screen, the press only does that
        if (splash != null && !splash.leaving()) {
            if (e.getAction() == KeyEvent.ACTION_DOWN) hideSplash.run();
            return true;
        }
        if (movingPkg != null && handleMoveKey(e)) return true;
        return super.dispatchKeyEvent(e);
    }

    // ── Move mode: ◀ ▶ (and ▲ ▼ in the grid) carry the tile, OK / Back put it down ──

    private String movingPkg;
    private boolean movingFav;
    private int gridCols = 4;
    private int favGridCols = 0;

    private void startMove(AppEntry a, boolean fav, AppTile t) {
        movingPkg = a.pkg;
        movingFav = fav;
        t.setMoving(true);
        t.requestFocus();
        Toast.makeText(this, T.t("Двигайте стрелками, ОК — готово"), Toast.LENGTH_SHORT).show();
    }

    private void stopMove() {
        movingPkg = null;
        View f = getCurrentFocus();
        if (f instanceof AppTile) ((AppTile) f).setMoving(false);
    }

    private boolean handleMoveKey(KeyEvent e) {
        int code = e.getKeyCode();
        if (code == KeyEvent.KEYCODE_HOME) { stopMove(); return false; }
        if (e.getAction() != KeyEvent.ACTION_DOWN) return true; // the whole press is ours
        int step;
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_LEFT: step = -1; break;
            case KeyEvent.KEYCODE_DPAD_RIGHT: step = 1; break;
            case KeyEvent.KEYCODE_DPAD_UP: step = movingFav ? -favGridCols : -gridCols; break;
            case KeyEvent.KEYCODE_DPAD_DOWN: step = movingFav ? favGridCols : gridCols; break;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
                stopMove();
                return true;
            default:
                return true;
        }
        if (step == 0) return true;
        List<AppEntry> list = new ArrayList<>(movingFav ? favorites : gridOrder);
        int j = -1;
        for (int k = 0; k < list.size(); k++) if (list.get(k).pkg.equals(movingPkg)) { j = k; break; }
        if (j < 0) { stopMove(); return true; }
        int to = Math.max(0, Math.min(list.size() - 1, j + step));
        if (to == j) return true;
        AppEntry a = list.remove(j);
        list.add(to, a);
        if (movingFav) saveFavorites(list); else saveOrder(list); // the screen redraws, focus follows the app
        return true;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent e) {
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            if (prefs.kids()) return true;
            View f = getCurrentFocus();
            if (f instanceof AppTile) { showOptions((AppTile) f); return true; }
        }
        return super.onKeyDown(keyCode, e);
    }

    // ── Data ────────────────────────────────────────────────────────────────

    private void reloadApps() {
        io.execute(() -> {
            final List<AppEntry> list = AppEntry.loadAll(this);
            final List<Inputs.Item> ins = Inputs.load(this);
            final Set<String> homes = new java.util.HashSet<>();
            try {
                for (android.content.pm.ResolveInfo ri : pm.queryIntentActivities(
                        new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)) {
                    homes.add(ri.activityInfo.packageName);
                }
            } catch (Throwable ignored) {}
            main.post(() -> {
                apps = list;
                inputs = ins;
                homeApps.clear();
                homeApps.addAll(homes);
                build();
                appsLoaded = true;
                maybeHideSplash();
            });
        });
    }

    private List<AppEntry> resolveFavorites(Set<String> hidden) {
        Map<String, AppEntry> byPkg = new HashMap<>();
        for (AppEntry a : apps) byPkg.put(a.pkg, a);
        List<AppEntry> out = new ArrayList<>();
        if (prefs.hasFavorites()) {
            for (String k : prefs.favorites()) {
                AppEntry a = byPkg.get(k);
                if (a != null && !hidden.contains(k)) out.add(a);
            }
            return out;
        }
        // First start: popular streaming apps that are installed, then TV apps.
        for (String k : DEFAULT_FAVORITES) {
            AppEntry a = byPkg.get(k);
            if (a != null && !hidden.contains(k) && !homeApps.contains(k) && out.size() < 6) out.add(a);
        }
        for (AppEntry a : apps) {
            if (out.size() >= 6) break;
            if (a.leanback && !out.contains(a) && !hidden.contains(a.pkg) && !homeApps.contains(a.pkg)) out.add(a);
        }
        return out;
    }

    /** Own order first (Prefs.order), then the rest in their usual (alphabetical) order. */
    private List<AppEntry> ordered(List<AppEntry> in) {
        Map<String, AppEntry> byPkg = new HashMap<>();
        for (AppEntry a : in) byPkg.put(a.pkg, a);
        List<AppEntry> out = new ArrayList<>();
        for (String k : prefs.order()) {
            AppEntry a = byPkg.remove(k);
            if (a != null) out.add(a);
        }
        for (AppEntry a : in) if (byPkg.containsKey(a.pkg)) out.add(a);
        return out;
    }

    private void saveOrder(List<AppEntry> list) {
        List<String> keys = new ArrayList<>();
        for (AppEntry a : list) keys.add(a.pkg);
        prefs.setOrder(keys);
    }

    private void saveFavorites(List<AppEntry> list) {
        List<String> keys = new ArrayList<>();
        for (AppEntry a : list) keys.add(a.pkg);
        prefs.setFavorites(keys);
    }

    // ── UI ──────────────────────────────────────────────────────────────────

    private void build() {
        String focusPkg = null;
        View cf = getCurrentFocus();
        if (cf instanceof AppTile) focusPkg = ((AppTile) cf).app.pkg;

        final Skin skin = prefs.skin();
        final boolean labelsAlways = prefs.labelsAlways();
        final Set<String> hidden = prefs.hidden();
        final boolean kids = prefs.kids();
        favorites = kids ? new ArrayList<AppEntry>() : resolveFavorites(hidden);
        final int size = prefs.tileSize();
        final int anim = prefs.anim();
        final int ringColor = prefs.ringAccent() ? skin.accent : 0xF2FFFFFF;
        final int cols = kids ? 4 : GRID_COLUMNS[size];
        gridCols = cols;
        final int favVisible = FAV_VISIBLE[size];

        // Own photo as background: decode off the UI thread, then redraw.
        // With "change the home background" on, the photo-frame photos take turns instead.
        final List<java.io.File> photoList = !kids && prefs.homePhotos() ? Photos.list(this) : new ArrayList<java.io.File>();
        String key = photoList.isEmpty() ? "w" + prefs.wallpaperRev() : "p" + prefs.photoRev();
        if (!key.equals(wallKey)) {
            wallKey = key;
            wallPending = true;
            io.execute(() -> {
                final android.graphics.Bitmap b = photoList.isEmpty() ? Wallpaper.load(this)
                        : Photos.load(this, photoList.get(homePhotoIdx % photoList.size()));
                main.post(() -> { wallBitmap = b; wallPending = false; build(); maybeHideSplash(); });
            });
        }

        int screenW = getResources().getDisplayMetrics().widthPixels;
        int padH = Math.round(screenW * 0.05f);          // TV overscan-safe margin
        int padV = Math.round(screenW * 0.03f);
        int gap = Ui.dp(this, 22);
        int contentW = screenW - 2 * padH;
        int favW = (contentW - 2 * Ui.dp(this, 22) - gap * (favVisible - 1)) / favVisible;
        int favH = favW * 9 / 16;
        int tileW = (contentW - gap * (cols - 1)) / cols;
        int tileH = tileW * 9 / 16;

        stopAmbient();
        ambientGlows.clear();
        root.removeAllViews();
        root.setBackground(Ui.background(skin));

        if (wallBitmap != null) {
            android.widget.ImageView wp = new android.widget.ImageView(this);
            wp.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
            wp.setImageBitmap(wallBitmap);
            wallView = wp;
            root.addView(wp, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            View dim = new View(this);
            // keeps text readable on any photo; the owner picks how much (0–90 %)
            dim.setBackgroundColor(Math.round(prefs.wallDim() * 2.55f) << 24);
            root.addView(dim, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        } else {
            wallView = null;
            // Accent glow in the top-right corner
            View glow = new View(this);
            int gs = Math.round(screenW * 0.7f);
            glow.setBackground(Ui.glow(skin.accent, gs / 2f));
            FrameLayout.LayoutParams glp = new FrameLayout.LayoutParams(gs, gs, Gravity.TOP | Gravity.END);
            glp.topMargin = -gs / 2;
            glp.rightMargin = -gs / 3;
            root.addView(glow, glp);
            ambientGlows.add(glow);
            if (prefs.ambient() && anim != Prefs.ANIM_OFF) {
                // a second, softer glow low on the left: the two drift slowly ("live" background)
                View glow2 = new View(this);
                int gs2 = Math.round(screenW * 0.55f);
                glow2.setBackground(Ui.glow(skin.accent, gs2 / 2f));
                glow2.setAlpha(.7f);
                FrameLayout.LayoutParams g2 = new FrameLayout.LayoutParams(gs2, gs2, Gravity.BOTTOM | Gravity.START);
                g2.bottomMargin = -gs2 / 2;
                g2.leftMargin = -gs2 / 4;
                root.addView(glow2, g2);
                ambientGlows.add(glow2);
            }
        }
        View vig = new View(this);
        vig.setBackground(Ui.vignette());
        root.addView(vig, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        if (!kids && prefs.style() == Prefs.STYLE_CLOCK && !showGrid) {
            buildClockHome(skin, screenW, padH, padV, anim, ringColor, focusPkg);
            return;
        }

        favTitle = null;
        favShelf = null;
        scroll = new ScrollView(this);
        // Back up to a favourite from the apps below: show the clock and the top bar too
        // (owners had to press Up three more times to see them). Hooked once per window.
        if (!focusHooked) {
            focusHooked = true;
            getWindow().getDecorView().getViewTreeObserver().addOnGlobalFocusChangeListener((was, now) -> {
                final ScrollView sc = scroll;
                if (now != null && sc != null && favShelf != null && sc.getScrollY() > 0
                        && isInside(now, favShelf) && (was == null || !isInside(was, favShelf))) {
                    sc.post(() -> sc.smoothScrollTo(0, 0));
                }
            });
        }
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setFillViewport(true);

        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setClipChildren(false);
        page.setClipToPadding(false);
        page.setPadding(padH, padV, padH, padV * 3);
        scroll.addView(page);

        page.addView(kids ? kidsBar() : topBar(skin));

        final int inputsPos = prefs.inputsPos();
        if (!kids && inputsPos == Prefs.INPUTS_TOP) addInputs(page);

        List<AppTile> tiles = new ArrayList<>();
        if (!favorites.isEmpty()) {
            favTitle = sectionTitle(T.t("Избранное"), Ui.dp(this, 30));
            page.addView(favTitle);
            FrameLayout shelf = new FrameLayout(this);
            favShelf = shelf;
            shelf.setBackground(Ui.shelf(Ui.dp(this, 30), prefs.shelf()));
            shelf.setClipChildren(true);
            LinearLayout.LayoutParams shp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            shp.topMargin = Ui.dp(this, 12);
            int inset = Ui.dp(this, 22);
            final int fc = prefs.favCols();
            favGridCols = fc;
            if (fc > 0) {
                // Several rows, fc per row: more favourites at a glance (owners asked for 6–8).
                LinearLayout grid = new LinearLayout(this);
                grid.setOrientation(LinearLayout.VERTICAL);
                grid.setClipChildren(false);
                grid.setClipToPadding(false);
                grid.setPadding(inset, Ui.dp(this, 10), inset, Ui.dp(this, 10));
                int fw = (contentW - 2 * inset - gap * (fc - 1)) / fc;
                int fh = fw * 9 / 16;
                LinearLayout row = null;
                for (int i = 0; i < favorites.size(); i++) {
                    if (i % fc == 0) {
                        row = row();
                        row.setPadding(0, Ui.dp(this, 6), 0, Ui.dp(this, 2));
                        grid.addView(row);
                    }
                    AppTile t = tile(favorites.get(i), fw, fh, skin, labelsAlways, fc >= 6 ? 12 : 13, 1.1f, anim, ringColor);
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                    if (i % fc > 0) lp.leftMargin = gap;
                    row.addView(t, lp);
                    tiles.add(t);
                }
                shelf.setClipChildren(false);
                shelf.addView(grid);
                page.addView(shelf, shp);
            } else {
            HorizontalScrollView hs = new HorizontalScrollView(this);
            hs.setClipChildren(true);
            hs.setClipToPadding(false);
            hs.setHorizontalScrollBarEnabled(false);
            hs.setOverScrollMode(View.OVER_SCROLL_NEVER);
            // room for the focused tile's zoom (≈8 %) so the glass never cuts it or its name
            int zoomPad = Math.round(favH * 0.06f) + Ui.dp(this, 6); // + the ring outside the card
            hs.setPadding(inset, Ui.dp(this, 16) + zoomPad, inset, Ui.dp(this, 12) + zoomPad);
            LinearLayout row = row();
            for (int i = 0; i < favorites.size(); i++) {
                AppTile t = tile(favorites.get(i), favW, favH, skin, labelsAlways, 15, 1.08f, anim, ringColor);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
            hs.addView(row);
            shelf.addView(hs);
            page.addView(shelf, shp);
            }
        }

        List<AppEntry> rest = new ArrayList<>();
        Set<String> allowed = prefs.kidsApps();
        for (AppEntry a : apps) {
            if (kids ? allowed.contains(a.pkg) : (!favorites.contains(a) && !hidden.contains(a.pkg))) rest.add(a);
        }
        if (!kids) rest = ordered(rest);
        gridOrder = rest;
        if (kids && rest.isEmpty() && !apps.isEmpty()) {
            TextView none = Ui.text(this, 18, 0x99FFFFFF, "sans-serif");
            none.setSingleLine(false);
            none.setText(T.t("Для детского режима ещё не выбраны приложения. Выйдите по PIN и выберите их в настройках."));
            LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            nlp.topMargin = Ui.dp(this, 40);
            page.addView(none, nlp);
        }
        if (!rest.isEmpty()) {
            final TextView appsTitle = sectionTitle(kids ? T.t("Можно смотреть") : T.t("Приложения"), Ui.dp(this, 26));
            page.addView(appsTitle);
            // "Apps on the second screen": the first screen shows only the top and favourites,
            // the grid starts just below it (▼ scrolls down to it).
            if (!kids && prefs.appsBelow()) {
                final int screenH = getResources().getDisplayMetrics().heightPixels;
                appsTitle.getViewTreeObserver().addOnGlobalLayoutListener(
                        new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
                    @Override public void onGlobalLayout() {
                        appsTitle.getViewTreeObserver().removeOnGlobalLayoutListener(this);
                        int sy = scroll != null ? scroll.getScrollY() : 0;
                        // favourites low on the first screen, over the photo (an owner's wish)
                        int favPush = 0;
                        if (prefs.favBottom() && favShelf != null && favTitle != null) {
                            int[] s = new int[2];
                            favShelf.getLocationOnScreen(s);
                            int bottom = s[1] + sy + favShelf.getHeight();
                            favPush = Math.max(0, screenH - Ui.dp(HomeActivity.this, 40) - bottom);
                            if (favPush > 0) {
                                LinearLayout.LayoutParams fl = (LinearLayout.LayoutParams) favTitle.getLayoutParams();
                                fl.topMargin += favPush;
                                favTitle.setLayoutParams(fl);
                            }
                        }
                        int[] at = new int[2];
                        appsTitle.getLocationOnScreen(at);
                        int top = at[1] + sy + favPush;
                        int push = screenH - top + Ui.dp(HomeActivity.this, 26);
                        if (push > 0) {
                            LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) appsTitle.getLayoutParams();
                            lp.topMargin += push;
                            appsTitle.setLayoutParams(lp);
                        }
                    }
                });
            }
            LinearLayout row = null;
            for (int i = 0; i < rest.size(); i++) {
                if (i % cols == 0) {
                    row = row();
                    row.setPadding(0, Ui.dp(this, 12) + Math.round(tileH * 0.05f), 0, Ui.dp(this, 4));
                    page.addView(row);
                }
                AppTile t = tile(rest.get(i), tileW, tileH, skin, kids || labelsAlways,
                        kids ? 16 : (size == Prefs.TILES_COMPACT ? 12 : 13), kids ? 1.08f : 1.12f, anim, ringColor);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i % cols > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
        }

        if (!kids && inputsPos == Prefs.INPUTS_BOTTOM) addInputs(page);

        if (apps.isEmpty()) {
            TextView empty = Ui.text(this, 18, 0x99FFFFFF, "sans-serif");
            empty.setText(T.t("Загружаем приложения…"));
            page.addView(empty);
        }

        root.addView(scroll, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // Restore focus to the same app, otherwise the first favourite.
        AppTile target = null;
        for (AppTile t : tiles) if (t.app.pkg.equals(focusPkg)) { target = t; break; }
        if (target == null && !tiles.isEmpty()) target = tiles.get(0);
        if (target != null) {
            target.requestFocus();
            if (target.app.pkg.equals(movingPkg)) target.setMoving(true);
        }

        if (!entered) {
            entered = true;
            for (int i = 0; i < tiles.size(); i++) tiles.get(i).enter(i);
        }
        loadArt(tiles);
        if (resumed) startAmbient();
    }

    private View topBar(Skin skin) {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        TextView greet = Ui.text(this, 15, 0xB3FFFFFF, "sans-serif-medium");
        greet.setText(greeting().toUpperCase());
        greet.setLetterSpacing(0.16f);
        greet.setPadding(0, 0, Ui.dp(this, 8), 0);
        left.addView(greet);

        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        timeRow.setGravity(Gravity.CENTER_VERTICAL);
        timeRow.addView(bigClock(64));

        View divider = new View(this);
        divider.setBackgroundColor(0x40FFFFFF);
        LinearLayout.LayoutParams dvp = new LinearLayout.LayoutParams(Ui.dp(this, 1), Ui.dp(this, 44));
        dvp.leftMargin = Ui.dp(this, 20);
        dvp.rightMargin = Ui.dp(this, 20);
        timeRow.addView(divider, dvp);

        // Day and date as two one-line clocks: one two-line clock with letter spacing was measured
        // a few pixels short on some TVs and broke «ВОСКРЕСЕНЬЕ» into «ВОСКРЕСЕНЬ / Е».
        LinearLayout dateCol = new LinearLayout(this);
        dateCol.setOrientation(LinearLayout.VERTICAL);
        dateCol.addView(dateLine("EEEE"));
        TextClock dayMonth = dateLine("d MMMM");
        LinearLayout.LayoutParams dml = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dml.topMargin = Ui.dp(this, 3);
        dateCol.addView(dayMonth, dml);
        weatherView = Ui.text(this, 15, 0xB3FFFFFF, "sans-serif-medium");
        LinearLayout.LayoutParams wl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wl.topMargin = Ui.dp(this, 4);
        dateCol.addView(weatherView, wl);
        updateWeatherView();
        timeRow.addView(dateCol);
        LinearLayout.LayoutParams trp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        trp.topMargin = Ui.dp(this, 4);
        left.addView(timeRow, trp);
        bar.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Pill net = new Pill(this, networkLabel());
        netPill = net;
        net.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
        bar.addView(net);

        Pill tvSettings = new Pill(this, T.t("Настройки ТВ"));
        tvSettings.setOnClickListener(v -> openSettings(Settings.ACTION_SETTINGS));
        LinearLayout.LayoutParams pp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        pp.leftMargin = Ui.dp(this, 14);
        bar.addView(tvSettings, pp);

        GearButton gear = new GearButton(this, skin.accent);
        int gs = Ui.dp(this, 46);
        LinearLayout.LayoutParams gp = new LinearLayout.LayoutParams(gs, gs);
        gp.leftMargin = Ui.dp(this, 14);
        gear.setOnClickListener(v -> startActivity(new Intent(this, SettingsActivity.class)));
        bar.addView(gear, gp);
        return bar;
    }

    private View kidsBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        TextView t = Ui.text(this, 15, prefs.skin().accent, "sans-serif-medium");
        t.setText(T.t("ДЕТСКИЙ РЕЖИМ"));
        t.setLetterSpacing(0.16f);
        left.addView(t);
        TextClock clock = new TextClock(this);
        String fmt = prefs.clock24() ? "HH:mm" : "h:mm";
        clock.setFormat24Hour(fmt);
        clock.setFormat12Hour(fmt);
        clock.setTextSize(64);
        clock.setTextColor(0xFFFFFFFF);
        clock.setTypeface(android.graphics.Typeface.create("sans-serif-thin", android.graphics.Typeface.NORMAL));
        left.addView(clock);
        bar.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Pill exit = new Pill(this, T.t("Выйти"));
        exit.setOnClickListener(v -> Pin.ask(this, T.t("PIN, чтобы выйти из детского режима"), pin -> {
            if (prefs.checkPin(pin)) prefs.setKids(false);
            else Toast.makeText(this, T.t("Неверный PIN"), Toast.LENGTH_SHORT).show();
        }));
        bar.addView(exit);
        return bar;
    }

    private Pill netPill;

    private final BroadcastReceiver netChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            main.postDelayed(() -> {
                if (netPill != null) netPill.setText(networkLabel());
                refreshWeather();
            }, 1500);
        }
    };

    private static boolean vpnOn(android.net.ConnectivityManager cm) {
        try {
            for (android.net.Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc != null && nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

    @SuppressWarnings("deprecation")
    private String networkLabel() {
        try {
            android.net.ConnectivityManager cm =
                    (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            android.net.NetworkInfo ni = cm == null ? null : cm.getActiveNetworkInfo();
            if (ni == null || !ni.isConnected()) return T.t("Нет сети");
            // The stock home showed «VPN is on» (Xiaomi, Haier owners missed it): we say it here.
            String vpn = vpnOn(cm) ? " · VPN" : "";
            if (ni.getType() == android.net.ConnectivityManager.TYPE_ETHERNET) return "Ethernet" + vpn;
            if (ni.getType() == android.net.ConnectivityManager.TYPE_WIFI) return "Wi-Fi" + vpn;
            if (ni.getType() == android.net.ConnectivityManager.TYPE_VPN) return "VPN";
            return T.t("В сети") + vpn;
        } catch (Throwable t) {
            return T.t("Сеть");
        }
    }

    private void openSettings(String action) {
        try {
            startActivity(new Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception e) {
            try { startActivity(new Intent(Settings.ACTION_SETTINGS)); } catch (Exception ignored) {}
        }
    }

    private String greeting() {
        int h = Calendar.getInstance().get(Calendar.HOUR_OF_DAY);
        if (h < 5) return T.t("Доброй ночи");
        if (h < 12) return T.t("Доброе утро");
        if (h < 18) return T.t("Добрый день");
        return T.t("Добрый вечер");
    }

    private void addInputs(LinearLayout page) {
        if (inputs.isEmpty()) return;
        {
            page.addView(sectionTitle(T.t("Источники"), Ui.dp(this, 26)));
            HorizontalScrollView ins = new HorizontalScrollView(this);
            ins.setHorizontalScrollBarEnabled(false);
            ins.setClipChildren(false);
            ins.setClipToPadding(false);
            ins.setPadding(Ui.dp(this, 4), Ui.dp(this, 10), Ui.dp(this, 4), Ui.dp(this, 4));
            LinearLayout irow = row();
            for (int i = 0; i < inputs.size(); i++) {
                final Inputs.Item it = inputs.get(i);
                Pill pill = new Pill(this, it.label);
                pill.setOnClickListener(v -> {
                    try { startActivity(Inputs.intent(it)); }
                    catch (Exception e) { Toast.makeText(this, T.f("Не удалось открыть {0}", it.label), Toast.LENGTH_SHORT).show(); }
                });
                LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i > 0) ip.leftMargin = Ui.dp(this, 12);
                irow.addView(pill, ip);
            }
            ins.addView(irow);
            page.addView(ins);
        }
    }

    private TextView sectionTitle(String s, int topMargin) {
        TextView t = Ui.text(this, 17, 0xB3FFFFFF, "sans-serif-medium");
        t.setText(s);
        t.setLetterSpacing(0.02f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = topMargin;
        t.setLayoutParams(lp);
        return t;
    }

    private LinearLayout row() {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setClipChildren(false);
        r.setClipToPadding(false);
        return r;
    }

    private AppTile tile(AppEntry a, int w, int h, Skin skin, boolean labelsAlways, float sp, float scale,
                         int anim, int ringColor) {
        AppTile t = new AppTile(this, a, w, h, skin, labelsAlways, sp, scale, anim, ringColor);
        t.setOnClickListener(v -> launch(a));
        t.setOnLongClickListener(v -> {
            if (!prefs.kids()) showOptions(t);
            return true;
        });
        return t;
    }

    // ── Live background: the accent glows drift slowly while Home is visible ──

    private void startAmbient() {
        if (ambientAnim != null || ambientGlows.size() < 2 || !prefs.ambient()
                || prefs.anim() == Prefs.ANIM_OFF || wallBitmap != null) return;
        final View a = ambientGlows.get(0), b = ambientGlows.get(1);
        final float dx = getResources().getDisplayMetrics().widthPixels * 0.06f;
        ambientAnim = android.animation.ValueAnimator.ofFloat(0f, 1f);
        ambientAnim.setDuration(prefs.anim() == Prefs.ANIM_SOFT ? 22000 : 14000);
        ambientAnim.setRepeatCount(android.animation.ValueAnimator.INFINITE);
        ambientAnim.setRepeatMode(android.animation.ValueAnimator.REVERSE);
        ambientAnim.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
        ambientAnim.addUpdateListener(v -> {
            float f = (float) v.getAnimatedValue();
            a.setTranslationX(-dx * f);
            a.setTranslationY(dx * 0.5f * f);
            a.setAlpha(0.75f + 0.25f * f);
            b.setTranslationX(dx * (1f - f));
            b.setTranslationY(-dx * 0.4f * (1f - f));
            b.setAlpha(0.45f + 0.35f * (1f - f));
        });
        ambientAnim.start();
    }

    private void stopAmbient() {
        if (ambientAnim != null) { ambientAnim.cancel(); ambientAnim = null; }
    }

    private void loadArt(List<AppTile> tiles) {
        for (final AppTile t : tiles) {
            final String k = t.app.pkg;
            Drawable cached = artCache.get(k);
            if (cached != null) {
                t.setArt(cached, Boolean.TRUE.equals(bannerCache.get(k)));
                continue;
            }
            io.execute(() -> {
                Drawable d = t.app.loadBanner(pm);
                boolean banner = d != null;
                if (d == null) d = t.app.loadIcon(pm);
                final Drawable art = d;
                main.post(() -> {
                    if (art == null) return;
                    artCache.put(k, art);
                    bannerCache.put(k, banner);
                    t.setArt(art, banner);
                });
            });
        }
    }

    private static boolean isInside(View v, View parent) {
        for (View p = v; p != null; p = p.getParent() instanceof View ? (View) p.getParent() : null) {
            if (p == parent) return true;
        }
        return false;
    }

    private void focusFirst() {
        if (scroll == null) return;
        View v = scroll.focusSearch(View.FOCUS_DOWN);
        if (v != null) v.requestFocus();
    }

    private void launch(AppEntry a) {
        // Opening the TV's own launcher on purpose: don't bounce back from it.
        HomeKeyService.allowedStockPkg = homeApps.contains(a.pkg) ? a.pkg : null;
        try {
            startActivity(a.launchIntent());
        } catch (ActivityNotFoundException | SecurityException e) {
            Toast.makeText(this, T.f("Не удалось открыть {0}", a.label), Toast.LENGTH_SHORT).show();
        }
    }

    // ── Long-press / Menu: edit favourites, hide, app info ─────────────────

    private void showOptions(AppTile t) {
        final AppEntry a = t.app;
        final boolean fav = favorites.contains(a);
        final List<String> items = new ArrayList<>();
        // actions by position: the labels are translated ([T])
        final List<String> acts = new ArrayList<>();
        acts.add(fav ? "unfav" : "fav");
        acts.add("move");
        final boolean auto = a.pkg.equals(prefs.autostart());
        acts.add(auto ? "noauto" : "auto");
        acts.add("hide");
        acts.add("info");
        items.add(fav ? T.t("Убрать из избранного") : T.t("Добавить в избранное"));
        items.add(T.t("Переместить"));
        items.add(auto ? T.t("Не открывать при включении ТВ") : T.t("Открывать при включении ТВ"));
        items.add(T.t("Скрыть с главного экрана"));
        items.add(T.t("О приложении"));

        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(a.label)
                .setItems(items.toArray(new String[0]), (d, which) -> {
                    String choice = acts.get(which);
                    List<AppEntry> favs = new ArrayList<>(favorites);
                    int i = favs.indexOf(a);
                    switch (choice) {
                        case "unfav": favs.remove(a); saveFavorites(favs); break;
                        case "fav": favs.add(a); saveFavorites(favs); break;
                        case "move":
                            startMove(a, fav, t);
                            break;
                        case "auto":
                            prefs.setAutostart(a.pkg);
                            Toast.makeText(this, T.f("{0} будет открываться при включении телевизора", a.label), Toast.LENGTH_LONG).show();
                            break;
                        case "noauto":
                            prefs.setAutostart("");
                            break;
                        case "hide": {
                            Set<String> h = prefs.hidden();
                            h.add(a.pkg);
                            favs.remove(a);
                            saveFavorites(favs);
                            prefs.setHidden(h);
                            break;
                        }
                        case "info":
                            try {
                                startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.fromParts("package", a.pkg, null)));
                            } catch (Exception ignored) {}
                            break;
                    }
                })
                .show();
    }
}
