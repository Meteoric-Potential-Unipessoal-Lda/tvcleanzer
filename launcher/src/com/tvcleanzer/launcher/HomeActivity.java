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
    /** «Витрина»: the blurred colour wash behind the focused app, per package. */
    private final Map<String, android.graphics.Bitmap> heroCache = new HashMap<>();
    private TextView heroTitle;
    private final android.widget.ImageView[] heroViews = new android.widget.ImageView[2];
    private int heroFront;
    private String heroPkg;
    private float heroAlpha = 0.95f;
    private final Runnable heroUpdate = this::updateHero;
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
                for (java.util.Iterator<String> it = artCache.keySet().iterator(); it.hasNext(); ) {
                    if (it.next().startsWith(pkg + "#")) it.remove();
                }
                for (java.util.Iterator<String> it = bannerCache.keySet().iterator(); it.hasNext(); ) {
                    if (it.next().startsWith(pkg + "#")) it.remove();
                }
                heroCache.remove(pkg);
            }
            reloadApps();
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        Glyphs.init(this);
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
        watchNetwork();
        watchBluetooth();
        reloadApps();
        maybeChooseInput(getIntent());
    }

    @Override
    protected void onDestroy() {
        prefs.sp.unregisterOnSharedPreferenceChangeListener(this);
        try { unregisterReceiver(packages); } catch (Exception ignored) {}
        try { unregisterReceiver(netChanged); } catch (Exception ignored) {}
        unwatchNetwork();
        if (btReceiver != null) {
            try { unregisterReceiver(btReceiver); } catch (Exception ignored) {}
            btReceiver = null;
        }
        io.shutdownNow();
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        if (prefs.nextSkinIfDue()) dirty = true; // «Менять тему сама»
        if (dirty) { dirty = false; build(); } else startAmbient();
        if (liveWall != null) liveWall.play();
        maybeAutostart();
        main.removeCallbacks(weatherTick);
        main.post(weatherTick);
        main.removeCallbacks(memTick);
        main.post(memTick); // right away: the TV may have slept for hours
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
        maybeChooseInput(intent);
    }

    /** The remote's Source key, answered by our key service where the stock home is off. */
    static final String EXTRA_INPUTS = "inputs";

    private void maybeChooseInput(Intent intent) {
        if (intent == null || !intent.getBooleanExtra(EXTRA_INPUTS, false)) return;
        intent.removeExtra(EXTRA_INPUTS);
        if (!appsLoaded) { chooseInputPending = true; return; } // the list is still loading
        if (inputs.isEmpty()) {
            Toast.makeText(this, T.t("Источники не найдены"), Toast.LENGTH_SHORT).show();
            return;
        }
        chooseInput();
    }

    private boolean chooseInputPending;

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
        if (prefs.clockGlass()) glassBehind(mid, center, padH);
        root.addView(mid, mlp);

        // Dock: inputs, favourites (icons), settings, all apps
        favGridCols = 0; // one row in the dock: ▲▼ do not move a favourite here
        LinearLayout dock = row();
        dock.setGravity(Gravity.CENTER_VERTICAL);
        dock.setBackground(Ui.shelf(Ui.dp(this, 34), prefs.shelf()));
        int dp18 = Ui.dp(this, 18);
        dock.setPadding(dp18, dp18, dp18, Ui.dp(this, 8));
        // the tile size setting works here too: compact / normal / large dock icons
        final float[] dockScale = {0.85f, 1f, 1.35f};
        int icon = Math.round(Math.max(Ui.dp(this, 64), Math.round(screenW * 0.05f)) * dockScale[prefs.tileSize()]);
        int gap = Ui.dp(this, 16);
        List<AppTile> tiles = new ArrayList<>();
        List<View> order = new ArrayList<>();

        final boolean withInput = !inputs.isEmpty() && prefs.inputsPos() != Prefs.INPUTS_HIDDEN;
        final int extras = withInput ? 3 : 2;
        final boolean round = prefs.icons() != Prefs.ICONS_BANNERS && prefs.iconShape() == Prefs.SHAPE_CIRCLE;
        // Like a Mac's dock: few apps — bigger icons (the size setting still scales them).
        int n = Math.min(8, favorites.size());
        icon = Math.round(icon * (n <= 4 ? 1.25f : n <= 6 ? 1.12f : 1f));
        // The whole dock must fit the screen (a centred dock wider than the screen loses both
        // ends): shrink the icons, then show fewer favourites, if needed.
        int avail = screenW - 2 * padH - 2 * dp18;
        while (n > 0 && (avail - gap * (n + extras - 1)) / (n + extras) < Ui.dp(this, 44)) n--;
        icon = Math.min(icon, (avail - gap * (n + extras - 1)) / (n + extras));
        if (withInput) {
            AppTile in = dockButton(Glyphs.INPUT, T.t("Источник"), icon, skin, anim, ringColor, round);
            in.setOnClickListener(v -> chooseInput());
            order.add(in);
        }
        for (int k = 0; k < n; k++) {
            AppTile t = tile(favorites.get(k), icon, icon, skin, false, 12, 1.12f, anim, ringColor);
            tiles.add(t);
            order.add(t);
        }
        AppTile gear = dockButton(Glyphs.GEAR, T.t("Настройки"), icon, skin, anim, ringColor, round);
        wireGear(gear);
        AppTile all = dockButton(Glyphs.MORE, T.t("Все приложения"), icon, skin, anim, ringColor, round);
        all.setOnClickListener(v -> { showGrid = true; build(); });
        order.add(gear);
        order.add(all);

        for (int i = 0; i < order.size(); i++) {
            View v = order.get(i);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
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
        // Wi-Fi / VPN, Bluetooth and the TV's settings up in the corner, like a tablet (the dock
        // has the gear already)
        if (prefs.barStyle() == Prefs.BAR_MINI && !prefs.cleanBar()) corner(skin, false);

        View target = null;
        for (AppTile t : tiles) if (t.app.pkg.equals(focusPkg)) { target = t; break; }
        if (target == null) target = tiles.isEmpty() ? all : tiles.get(0);
        target.requestFocus();
        if (target instanceof AppTile && ((AppTile) target).app.pkg.equals(movingPkg)) ((AppTile) target).setMoving(true);
        if (!entered) {
            entered = true;
            for (int i = 0; i < tiles.size(); i++) tiles.get(i).enter(i);
        }
        loadArt(tiles, true);
        if (resumed) startAmbient();
    }

    /**
     * «Витрина»: the focused app's own colours fill the screen behind a big title, with one row
     * of large tiles (favourites) and all apps below. Same spirit as premium TV boxes, own design:
     * no foreign logos, fonts or layout copied.
     */
    private void buildShowcaseHome(Skin skin, int screenW, int padH, int padV, int anim, int ringColor, String focusPkg) {
        final Set<String> hidden = prefs.hidden();
        final int screenH = getResources().getDisplayMetrics().heightPixels;
        final int size = prefs.tileSize();
        final int perRow = GRID_COLUMNS[size] - 1;     // 6 / 5 / 4 large tiles across
        final int contentW = screenW - 2 * padH;
        final int gap = Ui.dp(this, 20);
        final int tw = (contentW - gap * (perRow - 1)) / perRow;
        final int th = tw * 3 / 5;

        // The colour wash: two layers that cross-fade when the focus moves.
        heroAlpha = wallBitmap != null ? 0.45f : 0.95f;
        for (int i = 0; i < 2; i++) {
            android.widget.ImageView iv = new android.widget.ImageView(this);
            iv.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
            iv.setAlpha(0f);
            heroViews[i] = iv;
            root.addView(iv, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        }
        heroFront = 0;
        heroPkg = null;
        // shades: dark at the bottom (the tiles), a little at the top (clock) and on the left (title)
        View down = new View(this);
        down.setBackground(new android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0x59000000, 0x00000000, 0x00000000, 0xB305070D, 0xF205070D}));
        root.addView(down, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        View side = new View(this);
        side.setBackground(new android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.LEFT_RIGHT,
                new int[]{0x99000000, 0x00000000, 0x00000000}));
        root.addView(side, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        favTitle = null;
        favShelf = null;
        scroll = new ScrollView(this);
        hookFavScroll();
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
        page.addView(topBar(skin));
        final int inputsPos = prefs.inputsPos();
        if (inputsPos == Prefs.INPUTS_TOP) addInputs(page);

        // Big title of the focused app (can be switched off: «only takes room», owners said);
        // the old «ОК — открыть · …» hint line is gone for the same reason.
        final boolean showTitle = prefs.heroTitle();
        heroTitle = Ui.text(this, 46, 0xFFFFFFFF, "sans-serif");
        heroTitle.setTypeface(android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD));
        heroTitle.setShadowLayer(Ui.dp(this, 12), 0, Ui.dp(this, 2), 0x80000000);
        heroTitle.setSingleLine(true);
        heroTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                Math.round(contentW * 0.7f), ViewGroup.LayoutParams.WRAP_CONTENT);
        // Close under the clock: two full rows of tiles fit on the first screen (owners' wish:
        // «minimalism», nothing between the clock and the apps but the colours).
        hlp.topMargin = Math.round(screenH * 0.05f);
        page.addView(heroTitle, hlp);
        if (!showTitle) {
            heroTitle.setVisibility(View.GONE);
            View air = new View(this);
            page.addView(air, new LinearLayout.LayoutParams(1, Ui.dp(this, 10)));
        }

        final AppTile.Hook hook = this::showcaseFocused;
        final int zoomPad = Math.round(th * 0.09f) + Ui.dp(this, 8);
        List<AppTile> tiles = new ArrayList<>();

        // One row of large tiles: the favourites
        favGridCols = 0;
        if (!favorites.isEmpty()) {
            HorizontalScrollView hs = new HorizontalScrollView(this);
            hs.setHorizontalScrollBarEnabled(false);
            hs.setOverScrollMode(View.OVER_SCROLL_NEVER);
            hs.setClipChildren(false);
            hs.setClipToPadding(false);
            // the zoomed tile and its ring stay whole at both ends
            hs.setPadding(zoomPad, zoomPad, zoomPad, zoomPad);
            LinearLayout row = row();
            for (int i = 0; i < favorites.size(); i++) {
                AppTile t = tile(favorites.get(i), tw, th, skin, false, 15, 1.12f, anim, ringColor);
                t.hook = hook;
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
            hs.addView(row);
            favShelf = hs;
            LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            slp.topMargin = Ui.dp(this, 18) - zoomPad;
            slp.leftMargin = -zoomPad;
            slp.rightMargin = -zoomPad;
            page.addView(hs, slp);
        }

        // All other apps, same tiles, a grid below
        List<AppEntry> rest = new ArrayList<>();
        for (AppEntry a : apps) if (!favorites.contains(a) && !hidden.contains(a.pkg)) rest.add(a);
        rest = ordered(rest);
        gridOrder = rest;
        gridCols = perRow;
        if (!rest.isEmpty()) {
            // no «Приложения» heading here: the tiles speak for themselves
            LinearLayout row = null;
            View firstRow = null;
            for (int i = 0; i < rest.size(); i++) {
                if (i % perRow == 0) {
                    row = row();
                    row.setPadding(0, Ui.dp(this, 12) + Math.round(th * 0.06f), 0, Ui.dp(this, 4));
                    page.addView(row);
                    if (firstRow == null) firstRow = row;
                }
                AppTile t = tile(rest.get(i), tw, th, skin, prefs.labelsAlways(), 14, 1.12f, anim, ringColor);
                t.hook = hook;
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i % perRow > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
            // «Витрина» with only the favourites on the first screen; ▼ brings the rest (a
            // Grundig owner: the other apps crowded the showcase)
            if (prefs.appsBelow() && favShelf != null) pushBelow(favShelf, favShelf, firstRow, false);
        }
        if (inputsPos == Prefs.INPUTS_BOTTOM) addInputs(page);
        if (apps.isEmpty()) {
            TextView empty = Ui.text(this, 18, 0x99FFFFFF, "sans-serif");
            empty.setText(T.t("Загружаем приложения…"));
            page.addView(empty);
        }
        root.addView(scroll, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        AppTile target = null;
        for (AppTile t : tiles) if (t.app.pkg.equals(focusPkg)) { target = t; break; }
        if (target == null && !tiles.isEmpty()) target = tiles.get(0);
        if (target != null) {
            target.requestFocus();
            if (target.app.pkg.equals(movingPkg)) target.setMoving(true);
            showcaseFocused(target);
        }
        if (!entered) {
            entered = true;
            for (int i = 0; i < tiles.size(); i++) tiles.get(i).enter(i);
        }
        loadArt(tiles, true);
        if (resumed) startAmbient();
    }

    /** Title at once; the background a moment later (fast scrolling does not flash colours). */
    private void showcaseFocused(AppTile t) {
        if (heroTitle == null) return;
        heroTitle.setText(t.app.label);
        heroPkg = t.app.pkg;
        main.removeCallbacks(heroUpdate);
        main.postDelayed(heroUpdate, heroCache.containsKey(t.app.pkg) ? 60 : 160);
    }

    private void updateHero() {
        final String pkg = heroPkg;
        if (pkg == null || heroViews[0] == null) return;
        android.graphics.Bitmap b = heroCache.get(pkg);
        if (b != null) { showHero(b); return; }
        AppEntry found = null;
        for (AppEntry a : apps) if (a.pkg.equals(pkg)) { found = a; break; }
        if (found == null) return;
        final AppEntry app = found;
        io.execute(() -> {
            Drawable d = app.loadBanner(pm);
            if (d == null) d = IconArt.icon(pm, app);
            final android.graphics.Bitmap w = IconArt.wash(d);
            main.post(() -> {
                if (w == null) return;
                if (heroCache.size() > 24) heroCache.clear();
                heroCache.put(pkg, w);
                if (pkg.equals(heroPkg)) showHero(w);
            });
        });
    }

    private void showHero(android.graphics.Bitmap b) {
        android.widget.ImageView front = heroViews[heroFront], back = heroViews[1 - heroFront];
        if (front == null || back == null || front.getParent() == null) return;
        if (front.getTag() == b && front.getAlpha() > 0f) return;
        back.setImageBitmap(b);
        back.setTag(b);
        int dur = prefs.anim() == Prefs.ANIM_OFF ? 0 : (prefs.anim() == Prefs.ANIM_SOFT ? 700 : 450);
        back.animate().cancel();
        front.animate().cancel();
        if (dur == 0) {
            back.setAlpha(heroAlpha);
            front.setAlpha(0f);
        } else {
            back.setAlpha(0f);
            back.animate().alpha(heroAlpha).setDuration(dur).start();
            front.animate().alpha(0f).setDuration(dur).start();
        }
        heroFront = 1 - heroFront;
    }

    /** Back up to a favourite from the apps below: show the clock and the top bar too
     *  (owners had to press Up three more times to see them). Hooked once per window. */
    private void hookFavScroll() {
        if (focusHooked) return;
        focusHooked = true;
        getWindow().getDecorView().getViewTreeObserver().addOnGlobalFocusChangeListener((was, now) -> {
            final ScrollView sc = scroll;
            if (now != null && sc != null && favShelf != null && sc.getScrollY() > 0
                    && isInside(now, favShelf) && (was == null || !isInside(was, favShelf))) {
                sc.post(() -> sc.smoothScrollTo(0, 0));
            }
        });
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

    /** Long OK on «ТВ»: which app shows the broadcast. On a Sber TV the one found by itself
     *  opened but showed no broadcast, only the remote's TV key did (#22). */
    private void chooseTvApp() {
        if (prefs.kids()) return;
        final List<String> pk = Inputs.tvCandidates(this);
        final String own = prefs.tvApp();
        final String[] names = new String[pk.size() + 1];
        names[0] = (own.isEmpty() ? "✓ " : "") + T.t("Автоматически");
        for (int i = 0; i < pk.size(); i++) {
            String p = pk.get(i), l = p;
            try {
                l = String.valueOf(pm.getApplicationLabel(pm.getApplicationInfo(p, 0)));
            } catch (Throwable ignored) {}
            names[i + 1] = (p.equals(own) ? "✓ " : "") + (l.equals(p) ? p : l + "  ·  " + p);
        }
        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("Что открывать по «ТВ»"))
                .setItems(names, (d, w) -> {
                    prefs.setTvApp(w == 0 ? "" : pk.get(w - 1));
                    reloadApps();
                })
                .show();
    }

    private void openInput(Inputs.Item it) {
        HomeKeyService.quiet(15000);
        if (!Inputs.open(this, it)) Toast.makeText(this, T.f("Не удалось открыть {0}", it.label), Toast.LENGTH_SHORT).show();
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
        HomeKeyService.quiet(20000); // let the app / input come up without being replaced
        // A TV input: the TV is just a screen for a box on HDMI (a chat wish: Sber TV + Mi Stick).
        if (pkg.startsWith("input:")) {
            String id = pkg.substring(6);
            if (id.startsWith("tv:")) {
                Inputs.Item tv = Inputs.tv(c, true);
                return tv != null ? Inputs.open(c, tv) : openAutostart(c, id.substring(3));
            }
            return Inputs.open(c, new Inputs.Item(id, id));
        }
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
        main.removeCallbacks(memTick);
        main.removeCallbacks(homePhotoTick);
        stopAmbient();
        if (liveWall != null) liveWall.stop(); // the decoder goes back to the app in front
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
        if (quietOrder && (Prefs.ORDER.equals(key) || Prefs.FAVORITES.equals(key))) return;
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
        int code = e.getKeyCode();
        if (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER
                || code == KeyEvent.KEYCODE_NUMPAD_ENTER) {
            if (e.getAction() == KeyEvent.ACTION_DOWN) {
                okHeld = true;
            } else if (e.getAction() == KeyEvent.ACTION_UP) {
                okHeld = false;
                if (afterOk != null) {
                    final Runnable r = afterOk;
                    afterOk = null;
                    main.post(r);
                    return true; // this release belonged to the long press
                }
            }
        }
        int dir = e.getAction() == KeyEvent.ACTION_DOWN ? Ui.focusDir(code) : 0;
        View before = dir != 0 ? getCurrentFocus() : null;
        boolean handled = super.dispatchKeyEvent(e);
        if (handled && dir != 0) Ui.navSound(before, getCurrentFocus(), dir);
        return handled;
    }

    // ── Long OK: the menu opens when OK is let go (#15: on THOMSON the menu that opened under
    // a still-held OK froze, Back did nothing). Held too long — it opens anyway. ──

    private boolean okHeld;
    private Runnable afterOk;

    private void whenOkReleased(final Runnable r) {
        if (!okHeld) { r.run(); return; }
        afterOk = r;
        main.postDelayed(() -> {
            if (afterOk == r) {
                afterOk = null;
                okHeld = false;
                r.run();
            }
        }, 1500);
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
        // The tiles change places on screen as they are: no redraw of the whole home screen, so
        // nothing blinks (#52) and a held arrow can't outrun the redraw and put the tile back (#8).
        boolean moved = reorderInPlace(list);
        if (moved) {
            if (movingFav) favorites = list; else gridOrder = list;
        }
        quietOrder = moved;
        try {
            if (movingFav) saveFavorites(list); else saveOrder(list); // otherwise the screen redraws
        } finally {
            quietOrder = false;
        }
        return true;
    }

    /** Set while a move saves an order the screen already shows. */
    private boolean quietOrder;

    /** Puts the tiles of one section into [list]'s order, each into the next tile's slot. */
    private boolean reorderInPlace(List<AppEntry> list) {
        Set<String> want = new java.util.HashSet<>();
        for (AppEntry a : list) want.add(a.pkg);
        List<AppTile> found = new ArrayList<>();
        collectTiles(root, want, found);
        if (found.size() != list.size()) return false;
        Map<String, AppTile> byPkg = new HashMap<>();
        for (AppTile t : found) if (byPkg.put(t.app.pkg, t) != null) return false;
        int n = found.size();
        ViewGroup[] parents = new ViewGroup[n];
        int[] at = new int[n];
        ViewGroup.LayoutParams[] lps = new ViewGroup.LayoutParams[n];
        for (int i = 0; i < n; i++) {
            AppTile t = found.get(i);
            if (!(t.getParent() instanceof ViewGroup) || byPkg.get(list.get(i).pkg) == null) return false;
            parents[i] = (ViewGroup) t.getParent();
            at[i] = parents[i].indexOfChild(t);
            lps[i] = t.getLayoutParams(); // the slot's margins stay with the slot
        }
        AppTile mover = byPkg.get(movingPkg);
        // removing the focused tile would hand focus to the top of the screen (the page jumps):
        // with descendants blocked focus just goes quiet until the tile asks for it back
        int focusRule = root.getDescendantFocusability();
        root.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        try {
            for (int i = n - 1; i >= 0; i--) parents[i].removeView(found.get(i));
            for (int i = 0; i < n; i++) parents[i].addView(byPkg.get(list.get(i).pkg), at[i], lps[i]);
        } finally {
            root.setDescendantFocusability(focusRule);
        }
        if (mover != null) {
            mover.setMoving(true);
            mover.requestFocus();
        }
        return true;
    }

    private static void collectTiles(View v, Set<String> want, List<AppTile> out) {
        if (v instanceof AppTile) {
            if (want.contains(((AppTile) v).app.pkg)) out.add((AppTile) v);
            return;
        }
        if (!(v instanceof ViewGroup)) return;
        ViewGroup g = (ViewGroup) v;
        for (int i = 0; i < g.getChildCount(); i++) collectTiles(g.getChildAt(i), want, out);
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
                if (chooseInputPending) {
                    chooseInputPending = false;
                    if (!inputs.isEmpty()) chooseInput();
                }
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
        // «Живые обои»: the phone's video under everything (not with home photos, not for kids)
        final boolean live = !kids && photoList.isEmpty() && prefs.liveWallOn() && LiveWall.exists(this);
        showLiveWall(live, prefs.wallpaperRev());
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
        root.setBackground(live ? null : Ui.background(skin));

        if (live) {
            wallView = null;
            View dim = new View(this);
            dim.setBackgroundColor(Math.round(prefs.wallDim() * 2.55f) << 24);
            root.addView(dim, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        } else if (wallBitmap != null) {
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

        heroTitle = null;
        heroViews[0] = heroViews[1] = null;
        main.removeCallbacks(heroUpdate);
        if (!kids && prefs.style() == Prefs.STYLE_CLOCK && !showGrid) {
            buildClockHome(skin, screenW, padH, padV, anim, ringColor, focusPkg);
            return;
        }
        if (!kids && prefs.style() == Prefs.STYLE_SHOWCASE) {
            buildShowcaseHome(skin, screenW, padH, padV, anim, ringColor, focusPkg);
            return;
        }

        favTitle = null;
        favShelf = null;
        scroll = new ScrollView(this);
        hookFavScroll();
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
            // «Названия разделов» off: no heading, the shelf keeps the heading's place
            if (!prefs.sectionTitles()) favTitle.setVisibility(View.GONE);
            page.addView(favTitle);
            FrameLayout shelf = new FrameLayout(this);
            favShelf = shelf;
            shelf.setBackground(Ui.shelf(Ui.dp(this, 30), prefs.shelf()));
            shelf.setClipChildren(true);
            final int fc = prefs.favCols();
            // «Рамка избранного» (0.68): as wide as its tiles, on the left or in the middle (owners:
            // «зачем она на всю ширину?»), or the whole width; a grid always fills the width
            final int favAlign = fc > 0 ? Prefs.FAV_FULL : prefs.favAlign();
            LinearLayout.LayoutParams shp = new LinearLayout.LayoutParams(
                    favAlign == Prefs.FAV_FULL ? ViewGroup.LayoutParams.MATCH_PARENT : ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
            if (favAlign == Prefs.FAV_CENTER) {
                shp.gravity = Gravity.CENTER_HORIZONTAL;
                ((LinearLayout.LayoutParams) favTitle.getLayoutParams()).gravity = Gravity.CENTER_HORIZONTAL;
            }
            shp.topMargin = Ui.dp(this, 12);
            int inset = Ui.dp(this, 22);
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
            if (!kids && !prefs.sectionTitles()) appsTitle.setVisibility(View.GONE);
            page.addView(appsTitle);
            View firstRow = null;
            LinearLayout row = null;
            for (int i = 0; i < rest.size(); i++) {
                if (i % cols == 0) {
                    row = row();
                    row.setPadding(0, Ui.dp(this, 12) + Math.round(tileH * 0.05f), 0, Ui.dp(this, 4));
                    page.addView(row);
                    if (firstRow == null) firstRow = row;
                }
                AppTile t = tile(rest.get(i), tileW, tileH, skin, kids || labelsAlways,
                        kids ? 16 : (size == Prefs.TILES_COMPACT ? 12 : 13), kids ? 1.08f : 1.12f, anim, ringColor);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i % cols > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
            // "Apps on the second screen": the first screen shows only the top and favourites,
            // the grid starts just below it (▼ scrolls down to it)
            if (!kids && prefs.appsBelow()) {
                View favTop = favTitle != null && favTitle.getVisibility() == View.VISIBLE ? favTitle : favShelf;
                pushBelow(favTop, favShelf, appsTitle.getVisibility() == View.VISIBLE ? appsTitle : firstRow,
                        prefs.favBottom());
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
        loadArt(tiles, false);
        if (resumed) startAmbient();
    }

    private View topBar(Skin skin) {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        TextView greet = Ui.text(this, 15, 0xB3FFFFFF, "sans-serif-medium");
        greetView = greet;
        greet.setText(greeting().toUpperCase());
        greet.setLetterSpacing(0.16f);
        greet.setPadding(0, 0, Ui.dp(this, 8), 0);
        // «Приветствие» off: no greeting line (owners asked to drop it, 0.61)
        if (prefs.greeting()) left.addView(greet); else greetView = null;

        final boolean oneLine = prefs.oneLine();
        final int clockSp = new int[]{64, 46, 32}[prefs.barClock()];
        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        timeRow.setGravity(Gravity.CENTER_VERTICAL);
        timeRow.addView(bigClock(clockSp));

        View divider = new View(this);
        divider.setBackgroundColor(0x40FFFFFF);
        LinearLayout.LayoutParams dvp = new LinearLayout.LayoutParams(Ui.dp(this, 1),
                Ui.dp(this, oneLine ? Math.min(28, clockSp * 0.6f) : Math.min(44, clockSp * 0.75f)));
        dvp.leftMargin = Ui.dp(this, 20);
        dvp.rightMargin = Ui.dp(this, 20);
        timeRow.addView(divider, dvp);

        // Day and date as two one-line clocks: one two-line clock with letter spacing was measured
        // a few pixels short on some TVs and broke «ВОСКРЕСЕНЬЕ» into «ВОСКРЕСЕНЬ / Е».
        // «Дата и погода: в одну строку»: «ПЯТНИЦА, 22 НОЯБРЯ  ☁ +5°» beside the clock
        LinearLayout dateCol = new LinearLayout(this);
        dateCol.setOrientation(oneLine ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        dateCol.setGravity(Gravity.CENTER_VERTICAL);
        dateCol.addView(dateLine(oneLine ? "EEEE, d MMMM" : "EEEE"));
        if (!oneLine) {
            TextClock dayMonth = dateLine("d MMMM");
            LinearLayout.LayoutParams dml = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            dml.topMargin = Ui.dp(this, 3);
            dateCol.addView(dayMonth, dml);
        }
        weatherView = Ui.text(this, 15, 0xB3FFFFFF, "sans-serif-medium");
        LinearLayout.LayoutParams wl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        if (oneLine) wl.leftMargin = Ui.dp(this, 18); else wl.topMargin = Ui.dp(this, 4);
        dateCol.addView(weatherView, wl);
        updateWeatherView();
        timeRow.addView(dateCol);
        LinearLayout.LayoutParams trp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        trp.topMargin = Ui.dp(this, 4);
        left.addView(timeRow, trp);
        if (prefs.clockGlass()) {
            left.setBackground(Ui.shelf(Ui.dp(this, 26), prefs.shelf()));
            left.setPadding(Ui.dp(this, 24), Ui.dp(this, 14), Ui.dp(this, 28), Ui.dp(this, 16));
            bar.addView(left, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            bar.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1f));
        } else {
            bar.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        }

        memPill = null;
        btPill = null;
        btIcon = null;
        netPill = null;
        netIcon = null;
        netMini = null;
        vpnMini = null;
        memIcon = null;
        if (prefs.barStyle() == Prefs.BAR_MINI) {
            corner(skin, true);
            return bar;
        }
        if (prefs.memPill()) {
            Pill mem = new Pill(this, Memory.label(this));
            memPill = mem;
            mem.setOnClickListener(v -> freeMemory());
            LinearLayout.LayoutParams mp = pillLp();
            mp.rightMargin = Ui.dp(this, 14);
            bar.addView(mem, mp);
        }

        // Bluetooth (0.63, asked in the chat): on / off / what is connected; OK switches it
        btPill = null;
        btIcon = null;
        int bts = prefs.btPill() && !prefs.cleanBar() ? Bt.state(this) : Bt.NONE;
        if (bts != Bt.NONE) {
            int is = Ui.dp(this, 46);
            final boolean icons = prefs.barStyle() == Prefs.BAR_ICONS;
            LinearLayout.LayoutParams bp = icons ? new LinearLayout.LayoutParams(is, is) : pillLp();
            bp.rightMargin = Ui.dp(this, 14);
            if (icons) {
                TopIcon bt = new TopIcon(this, bts == Bt.OFF ? TopIcon.BT_OFF : TopIcon.BT, btColour(bts));
                btIcon = bt;
                bt.setOnClickListener(v -> bluetoothMenu());
                bar.addView(bt, bp);
            } else {
                Pill bt = new Pill(this, btLabel(bts));
                btPill = bt;
                bt.setOnClickListener(v -> bluetoothMenu());
                bar.addView(bt, bp);
            }
            btShown = bts;
        }

        netPill = null;
        netIcon = null;
        if (!prefs.cleanBar() && prefs.barStyle() == Prefs.BAR_ICONS) {
            // round icons instead of words; the network one in a status colour
            int[] ns = netState();
            TopIcon net = new TopIcon(this, ns[0], ns[1]);
            netIcon = net;
            net.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
            int is = Ui.dp(this, 46);
            bar.addView(net, new LinearLayout.LayoutParams(is, is));
            TopIcon tv = new TopIcon(this, TopIcon.TV, 0);
            tv.setOnClickListener(v -> openSettings(Settings.ACTION_SETTINGS));
            LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(is, is);
            tp.leftMargin = Ui.dp(this, 14);
            bar.addView(tv, tp);
        } else if (!prefs.cleanBar()) {
            Pill net = new Pill(this, networkLabel());
            netPill = net;
            net.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
            bar.addView(net, pillLp());

            Pill tvSettings = new Pill(this, T.t("Настройки ТВ"));
            tvSettings.setOnClickListener(v -> openSettings(Settings.ACTION_SETTINGS));
            LinearLayout.LayoutParams pp = pillLp();
            pp.leftMargin = Ui.dp(this, 14);
            bar.addView(tvSettings, pp);
        }

        GearButton gear = new GearButton(this, skin.accent);
        int gs = Ui.dp(this, 46);
        LinearLayout.LayoutParams gp = new LinearLayout.LayoutParams(gs, gs);
        gp.leftMargin = Ui.dp(this, 14);
        wireGear(gear);
        bar.addView(gear, gp);
        return bar;
    }

    /** The gear: launcher settings; with «Только шестерёнка вверху» the TV's own settings, and
     *  holding OK on it opens the launcher's. */
    /** Mini top bar (0.68, the default): small white symbols in the screen's top-right corner on
     *  one shared glass panel (0.72, the project's icon pack: Wi-Fi, the VPN plate only while a
     *  VPN is on, Bluetooth, the TV's settings, the gear), memory as a word first. Fixed: stays
     *  when the page scrolls. The dock home has its own gear. */
    private void corner(Skin skin, boolean withGear) {
        android.util.DisplayMetrics dm = getResources().getDisplayMetrics();
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        final int h = Ui.dp(this, 36), gap = Ui.dp(this, 6), ph = Ui.dp(this, 8), pv = Ui.dp(this, 5);
        // one glass under all of them, the same look as every other glass on the screen («Стекло»)
        row.setBackground(Ui.shelf((h + 2 * pv) * 0.34f, prefs.shelf()));
        row.setPadding(ph, pv, ph, pv);
        final boolean clean = prefs.cleanBar();
        List<View> items = new ArrayList<>();
        if (prefs.memPill() && !clean) {
            // memory as an icon like the others (0.74: the words «ОЗУ 1,1 / 1,7 ГБ» stood out in
            // the panel); its numbers show beside it while it is selected; OK frees memory
            final TextView label = Ui.text(this, 14, 0xF2FFFFFF, "sans-serif-medium");
            label.setText(Memory.label(this));
            label.setSingleLine(true);
            label.setGravity(Gravity.CENTER_VERTICAL);
            label.setPadding(Ui.dp(this, 6), 0, Ui.dp(this, 2), 0);
            label.setVisibility(View.GONE);
            memPill = label;
            TopIcon mem = new TopIcon(this, TopIcon.MEM, memStatus(), true);
            memIcon = mem;
            mem.hook = has -> label.setVisibility(has || freeing ? View.VISIBLE : View.GONE);
            mem.setOnClickListener(v -> freeMemory());
            items.add(label);
            items.add(mem);
        }
        if (!clean) {
            TopIcon net = new TopIcon(this, TopIcon.WIFI, 0, true);
            netMini = net;
            net.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
            items.add(net);
            TopIcon vpn = new TopIcon(this, TopIcon.VPN_PLATE, 0, true);
            vpnMini = vpn;
            vpn.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
            items.add(vpn);
        }
        int bts = prefs.btPill() && !clean ? Bt.state(this) : Bt.NONE;
        if (bts != Bt.NONE) {
            TopIcon bt = new TopIcon(this, bts == Bt.OFF ? TopIcon.BT_OFF : TopIcon.BT, btColour(bts), true);
            btIcon = bt;
            btShown = bts;
            bt.setOnClickListener(v -> bluetoothMenu());
            items.add(bt);
        }
        if (!clean) {
            TopIcon tv = new TopIcon(this, TopIcon.TV, 0, true);
            tv.setOnClickListener(v -> openSettings(Settings.ACTION_SETTINGS));
            items.add(tv);
        }
        if (withGear) {
            TopIcon gear = new TopIcon(this, TopIcon.GEAR, 0, true);
            wireGear(gear);
            items.add(gear);
        }
        if (items.isEmpty()) return;
        for (int i = 0; i < items.size(); i++) {
            View v = items.get(i);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    v instanceof TopIcon ? h : ViewGroup.LayoutParams.WRAP_CONTENT, h);
            if (i > 0) lp.leftMargin = gap;
            row.addView(v, lp);
        }
        if (netMini != null) miniNet(netMini);
        FrameLayout.LayoutParams clp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.END);
        clp.topMargin = Math.max(Ui.dp(this, 12), Math.round(dm.heightPixels * 0.028f));
        clp.rightMargin = Math.max(Ui.dp(this, 16), Math.round(dm.widthPixels * 0.02f));
        row.setTranslationZ(Ui.dp(this, 30)); // over the page that scrolls under it
        root.addView(row, clp);
    }

    /** The mini network icon: Wi-Fi or Ethernet, orange without internet; the VPN plate beside
     *  it only while a VPN is on. */
    private void miniNet(TopIcon t) {
        int[] s = netState();
        int glyph = s[2] == NET_OFF ? TopIcon.OFFLINE : s[4] == 2 ? TopIcon.ETHERNET : TopIcon.WIFI;
        int st = s[2] == NET_OFF ? TopIcon.OFF : s[2] == NET_NO_INTERNET ? TopIcon.BAD : 0;
        t.set(glyph, st);
        if (vpnMini != null) {
            int want = s[3] == 1 ? View.VISIBLE : View.GONE;
            if (vpnMini.getVisibility() != want) vpnMini.setVisibility(want);
        }
    }

    /** A word in the corner panel (memory): white, the pack's focus frame round it. */
    private TextView miniText(String s, int h) {
        final TextView t = Ui.text(this, 14, 0xF2FFFFFF, "sans-serif-medium");
        t.setText(s);
        t.setSingleLine(true);
        t.setGravity(Gravity.CENTER);
        t.setPadding(Ui.dp(this, 10), 0, Ui.dp(this, 10), 0);
        t.setFocusable(true);
        t.setClickable(true);
        if (android.os.Build.VERSION.SDK_INT >= 26) t.setDefaultFocusHighlightEnabled(false);
        final android.graphics.drawable.GradientDrawable ring = new android.graphics.drawable.GradientDrawable();
        ring.setColor(0x21FFFFFF);
        ring.setCornerRadius(h * 0.31f);
        ring.setStroke(Math.max(2, Math.round(h * 0.035f)), 0xE6FFFFFF);
        t.setOnFocusChangeListener((v, has) -> t.setBackground(has ? ring : null));
        return t;
    }

    /** A dock button that is not an app: a grey square (or circle) with a glyph, exactly the
     *  size of the app icons beside it; its name shows under it on focus. */
    private AppTile dockButton(int glyph, String label, int size, Skin skin, int anim, int ringColor, boolean round) {
        AppTile t = new AppTile(this, AppEntry.special("tvcleanzer:dock" + glyph, label), size, size, skin, false, 12,
                1.12f, anim, ringColor);
        t.setArt(new Glyphs.Face(glyph, round), true);
        t.setRound(round);
        return t;
    }

    /** Glass under the big clock, date and weather (clock home): as wide as the longest line. */
    private void glassBehind(final LinearLayout mid, final boolean center, final int padH) {
        final View glass = new View(this);
        glass.setBackground(Ui.shelf(Ui.dp(this, 30), prefs.shelf()));
        root.addView(glass, new FrameLayout.LayoutParams(0, 0, Gravity.TOP | Gravity.START));
        final int gp = Ui.dp(this, 30);
        mid.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
            float cw = 0;
            int top = Integer.MAX_VALUE, bottom = 0;
            for (int i = 0; i < mid.getChildCount(); i++) {
                View ch = mid.getChildAt(i);
                if (!(ch instanceof TextView) || ch.getVisibility() != View.VISIBLE) continue;
                TextView tv = (TextView) ch;
                if (tv.getLayout() == null || tv.getText().length() == 0) continue;
                cw = Math.max(cw, tv.getLayout().getLineWidth(0));
                top = Math.min(top, ch.getTop());
                bottom = Math.max(bottom, ch.getBottom());
            }
            if (cw <= 0) return;
            int w = Math.round(cw) + 2 * gp;
            int x = center ? l + (r - l - w) / 2 : l + padH - gp;
            int y = t + top - gp / 2, hh = bottom - top + gp;
            final FrameLayout.LayoutParams gl = (FrameLayout.LayoutParams) glass.getLayoutParams();
            if (gl.width == w && gl.height == hh && gl.leftMargin == Math.max(0, x) && gl.topMargin == Math.max(0, y)) return;
            gl.width = w;
            gl.height = hh;
            gl.leftMargin = Math.max(0, x);
            gl.topMargin = Math.max(0, y);
            glass.post(() -> glass.setLayoutParams(gl));
        });
    }

    private void wireGear(View gear) {
        if (prefs.cleanBar()) {
            // OK asks which settings: holding OK was the only way into the launcher's own ones,
            // and nobody knew it (a Yandex TV owner: «пропала шестерёнка», the gear always
            // opened the TV panel); long press stays as a shortcut
            gear.setOnClickListener(v -> new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                    .setItems(new String[]{T.t("Настройки ТВ"), T.t("Настройки лаунчера")}, (d, which) -> {
                        if (which == 0) openSettings(Settings.ACTION_SETTINGS);
                        else startActivity(new Intent(this, SettingsActivity.class));
                    })
                    .show());
            gear.setOnLongClickListener(v -> { startActivity(new Intent(this, SettingsActivity.class)); return true; });
        } else {
            gear.setOnClickListener(v -> startActivity(new Intent(this, SettingsActivity.class)));
        }
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
    private TopIcon netIcon;
    private TextView memPill;
    private TopIcon netMini, vpnMini, memIcon;

    /** Orange when the TV is nearly out of memory. */
    private int memStatus() {
        try {
            long[] m = Memory.read(this);
            return m[1] > 0 && (m[1] - m[0]) * 100 / m[1] >= 85 ? TopIcon.BAD : 0;
        } catch (Throwable t) {
            return 0;
        }
    }
    private TextView greetView;

    /** Every pill of the top bar: one height (the gear's), centred on one line. */
    private LinearLayout.LayoutParams pillLp() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, Ui.dp(this, 46));
        lp.gravity = Gravity.CENTER_VERTICAL;
        return lp;
    }

    /** Greeting, network and memory follow the clock: the TV sleeps for hours and wakes up
     *  to an old screen (owners saw «Добрый вечер» at night, «Нет сети» with Wi-Fi up). */
    private void refreshStatus() {
        if (greetView != null) {
            String g = greeting().toUpperCase();
            if (!g.contentEquals(greetView.getText())) greetView.setText(g);
        }
        if (netPill != null) {
            CharSequence n = networkLabel();
            int colour = netState()[1];
            if (!n.toString().equals(netPill.getText().toString()) || colour != netPillColour) netPill.setText(n);
            netPillColour = colour;
        }
        if (netIcon != null) {
            int[] ns = netState();
            netIcon.set(ns[0], ns[1]);
        }
        if (netMini != null) miniNet(netMini);
        if (memPill != null && !freeing) memPill.setText(Memory.label(this));
        if (memIcon != null) memIcon.set(TopIcon.MEM, memStatus());
        if (btPill != null || btIcon != null) {
            int st = Bt.state(this);
            if (btPill != null) {
                CharSequence l = btLabel(st);
                if (st != btShown || !l.toString().equals(btPill.getText().toString())) btPill.setText(l);
            }
            if (btIcon != null) btIcon.set(st == Bt.OFF ? TopIcon.BT_OFF : TopIcon.BT, btColour(st));
            btShown = st;
        }
    }
    private boolean freeing;

    // ── Bluetooth pill / icon (0.63) ──
    private Pill btPill;
    private TopIcon btIcon;
    private int btShown;
    private android.content.BroadcastReceiver btReceiver;

    /** Blue: something is connected; white: on; grey: off. */
    private static int btColour(int st) {
        return st == Bt.CONNECTED ? TopIcon.VPN_COLOR : st == Bt.OFF ? TopIcon.IDLE : 0;
    }

    private CharSequence btLabel(int st) {
        android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder("\u25CF  ");
        int c = btColour(st);
        sb.setSpan(new android.text.style.ForegroundColorSpan(c == 0 ? 0xFFFFFFFF : c), 0, 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return sb.append(Bt.label(this, st));
    }

    /** Turned on or off, a device connected or gone: the pill follows at once. */
    private void watchBluetooth() {
        if (btReceiver != null || Bt.adapter(this) == null) return;
        btReceiver = new android.content.BroadcastReceiver() {
            @Override public void onReceive(android.content.Context c, Intent i) {
                main.removeCallbacks(netRefresh);
                main.postDelayed(netRefresh, 700);
            }
        };
        IntentFilter f = new IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED);
        f.addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED);
        f.addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_DISCONNECTED);
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(btReceiver, f, android.content.Context.RECEIVER_EXPORTED);
            else registerReceiver(btReceiver, f);
        } catch (Throwable t) {
            btReceiver = null;
        }
    }

    /** OK on the pill: switch it, or open the TV's Bluetooth settings (pair a device). */
    private void bluetoothMenu() {
        final boolean on = Bt.state(this) != Bt.OFF;
        java.util.List<String> names = Bt.connected(this, false);
        String title = names.isEmpty() ? "Bluetooth" : "Bluetooth: " + android.text.TextUtils.join(", ", names);
        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(title)
                .setItems(new String[]{on ? T.t("Выключить Bluetooth") : T.t("Включить Bluetooth"),
                        T.t("Настройки Bluetooth")}, (d, which) -> {
                    if (which == 1) {
                        openSettings(Settings.ACTION_BLUETOOTH_SETTINGS);
                    } else if (on && !Bt.connected(this, true).isEmpty()) {
                        // a Bluetooth remote would go dead with it: say so first
                        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                                .setTitle(T.t("Выключить Bluetooth?"))
                                .setMessage(T.t("Пульт или клавиатура подключены по Bluetooth: после выключения они перестанут работать. Включить обратно можно кнопками на самом телевизоре или из TVCleanzer на телефоне («Пульт»)."))
                                .setPositiveButton(T.t("Выключить"), (d2, w2) -> switchBluetooth(false))
                                .setNegativeButton(T.t("Отмена"), null)
                                .show();
                    } else {
                        switchBluetooth(!on);
                    }
                })
                .show();
    }

    private void switchBluetooth(boolean on) {
        if (Bt.set(this, on)) {
            main.postDelayed(netRefresh, 1500);
            return;
        }
        // Android 13+: only the system switches it; turning on may still be asked for
        if (on) {
            try {
                startActivity(new Intent(android.bluetooth.BluetoothAdapter.ACTION_REQUEST_ENABLE));
                main.postDelayed(netRefresh, 3000);
                return;
            } catch (Throwable ignored) {}
        }
        Toast.makeText(this, T.t("На этом телевизоре Bluetooth переключается в его настройках"), Toast.LENGTH_LONG).show();
        openSettings(Settings.ACTION_BLUETOOTH_SETTINGS);
    }

    // ── «Живые обои» (0.61+): a video view under [root] in [frame], kept across redraws ──
    private LiveWall liveWall;
    private long liveRev;

    private void showLiveWall(boolean on, long rev) {
        if (!on) {
            if (liveWall != null) {
                liveWall.stop();
                frame.removeView(liveWall);
                liveWall = null;
            }
            return;
        }
        if (liveWall == null) {
            liveWall = new LiveWall(this);
            frame.addView(liveWall, 0, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            frame.setBackground(Ui.background(prefs.skin())); // until the first frame
            liveRev = rev;
        } else if (rev != liveRev) {
            liveRev = rev;
            liveWall.reload();
        }
        if (resumed) liveWall.play();
    }
    private int netPillColour;

    /** Network changes as they happen (Android 7+): VPN on/off and «no internet» send no
     *  CONNECTIVITY_CHANGE, the pill waited for the 10-second tick or showed old news. */
    private Object netCallback;
    private final Runnable netRefresh = this::refreshStatus;

    private void watchNetwork() {
        if (android.os.Build.VERSION.SDK_INT < 24) return;
        try {
            android.net.ConnectivityManager cm =
                    (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            android.net.ConnectivityManager.NetworkCallback cb = new android.net.ConnectivityManager.NetworkCallback() {
                private void later() {
                    main.removeCallbacks(netRefresh);
                    main.postDelayed(netRefresh, 700);
                }
                @Override public void onAvailable(android.net.Network n) { later(); }
                @Override public void onLost(android.net.Network n) { later(); }
                @Override public void onCapabilitiesChanged(android.net.Network n, android.net.NetworkCapabilities c) { later(); }
            };
            cm.registerDefaultNetworkCallback(cb);
            netCallback = cb;
        } catch (Throwable ignored) {}
    }

    private void unwatchNetwork() {
        if (netCallback == null || android.os.Build.VERSION.SDK_INT < 24) return;
        try {
            ((android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE))
                    .unregisterNetworkCallback((android.net.ConnectivityManager.NetworkCallback) netCallback);
        } catch (Throwable ignored) {}
        netCallback = null;
    }

    /** RAM pill: closes background apps, then says how much came free. */
    private void freeMemory() {
        if (freeing) return;
        freeing = true;
        if (memPill != null) memPill.setText(T.t("Освобождаем память…"));
        io.execute(() -> {
            final long mb = Memory.free(this);
            main.post(() -> {
                freeing = false;
                if (memPill != null) memPill.setText(Memory.label(this));
                Toast.makeText(this, mb >= 10 ? T.f("Освобождено {0} МБ", String.valueOf(mb))
                        : T.t("Лишнего в памяти нет"), Toast.LENGTH_SHORT).show();
            });
        });
    }

    private final Runnable memTick = new Runnable() {
        @Override public void run() {
            refreshStatus();
            if (resumed) main.postDelayed(this, 10 * 1000L);
        }
    };

    private final BroadcastReceiver netChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            main.postDelayed(() -> {
                refreshStatus();
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

    /** What the network pill / icon shows: 0 no network, 1 network without internet, 2 online, 3 VPN. */
    static final int NET_OFF = 0, NET_NO_INTERNET = 1, NET_OK = 2, NET_VPN = 3;

    /** {glyph, colour, kind, vpn 0/1, link: 0 other, 1 Wi-Fi, 2 Ethernet} for the network icon and pill.
     *  One colour per state everywhere (owners asked to tell them apart at a glance, 0.61):
     *  green online, blue VPN, orange connected without internet, red no network. */
    @SuppressWarnings("deprecation")
    private int[] netState() {
        try {
            android.net.ConnectivityManager cm =
                    (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            android.net.NetworkInfo ni = cm == null ? null : cm.getActiveNetworkInfo();
            if (ni == null || !ni.isConnected()) return new int[]{TopIcon.OFFLINE, TopIcon.OFF, NET_OFF, 0, 0};
            boolean vpn = vpnOn(cm) || ni.getType() == android.net.ConnectivityManager.TYPE_VPN;
            int link = linkOf(cm, ni);
            boolean online = true;
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
                online = nc == null || nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            }
            if (vpn) {
                return new int[]{TopIcon.VPN, online ? TopIcon.VPN_COLOR : TopIcon.BAD,
                        online ? NET_VPN : NET_NO_INTERNET, 1, link};
            }
            int glyph = link == 2 ? TopIcon.ETHERNET : TopIcon.WIFI;
            return new int[]{glyph, online ? TopIcon.OK : TopIcon.BAD, online ? NET_OK : NET_NO_INTERNET, 0, link};
        } catch (Throwable t) {
            return new int[]{TopIcon.WIFI, 0, NET_OK, 0, 1};
        }
    }

    /** Wi-Fi or Ethernet under the active network (with a VPN on, the active one is the VPN). */
    @SuppressWarnings("deprecation")
    private static int linkOf(android.net.ConnectivityManager cm, android.net.NetworkInfo ni) {
        if (ni.getType() == android.net.ConnectivityManager.TYPE_ETHERNET) return 2;
        if (ni.getType() == android.net.ConnectivityManager.TYPE_WIFI) return 1;
        try {
            for (android.net.Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue;
                if (nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) return 2;
                if (nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) return 1;
            }
        } catch (Throwable ignored) {}
        return 0;
    }

    /** The network pill's text: a dot in the state colour, the link, «нет интернета» when it
     *  has none, and the «🔒 VPN» badge. */
    private CharSequence networkLabel() {
        try {
            int[] s = netState();
            android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder("\u25CF  ");
            sb.setSpan(new android.text.style.ForegroundColorSpan(s[1] == 0 ? TopIcon.OK : s[1]), 0, 1,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            if (s[2] == NET_OFF) return sb.append(T.t("Нет сети"));
            sb.append(s[4] == 2 ? "Ethernet" : s[4] == 1 ? "Wi-Fi" : T.t("В сети"));
            if (s[2] == NET_NO_INTERNET) sb.append(" \u00B7 ").append(T.t("нет интернета"));
            if (s[3] == 1) {
                int at = sb.length();
                sb.append('\uFFFC');
                sb.setSpan(new VpnBadge(getResources().getDisplayMetrics().density), at, at + 1,
                        android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
            return sb;
        } catch (Throwable t) {
            return T.t("Сеть");
        }
    }

    /** Blue capsule with a padlock and «VPN» (the VPN colour everywhere), drawn inside the network pill's text. */
    static final class VpnBadge extends android.text.style.ReplacementSpan {
        private final float dp;
        private final android.graphics.Paint p = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
        VpnBadge(float density) { dp = density; }

        private void prep(android.graphics.Paint base) {
            p.set(base);
            p.setTextSize(base.getTextSize() * 0.7f);
            p.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.BOLD));
        }
        private float lockW() { return p.getTextSize() * 0.62f; }
        private float boxW() { return 7 * dp + lockW() + 4 * dp + p.measureText("VPN") + 8 * dp; }

        @Override public int getSize(android.graphics.Paint paint, CharSequence text, int start, int end,
                                     android.graphics.Paint.FontMetricsInt fm) {
            prep(paint);
            return Math.round(9 * dp + boxW());
        }

        @Override public void draw(android.graphics.Canvas c, CharSequence text, int start, int end,
                                   float x, int top, int y, int bottom, android.graphics.Paint paint) {
            prep(paint);
            float h = p.getTextSize() * 1.55f;
            float cy = y + (paint.ascent() + paint.descent()) / 2f;
            float l = x + 9 * dp, w = boxW();
            p.setStyle(android.graphics.Paint.Style.FILL);
            p.setColor(TopIcon.VPN_COLOR);
            c.drawRoundRect(new android.graphics.RectF(l, cy - h / 2, l + w, cy + h / 2), h / 2, h / 2, p);
            // padlock: shackle arc + body
            float lw = lockW(), lx = l + 7 * dp;
            float bodyH = lw * 0.72f, bodyTop = cy - bodyH * 0.25f;
            p.setColor(0xFFFFFFFF);
            c.drawRoundRect(new android.graphics.RectF(lx, bodyTop, lx + lw, bodyTop + bodyH), lw * 0.15f, lw * 0.15f, p);
            p.setStyle(android.graphics.Paint.Style.STROKE);
            p.setStrokeWidth(Math.max(1.5f, lw * 0.14f));
            float sr = lw * 0.3f, scx = lx + lw / 2;
            c.drawArc(new android.graphics.RectF(scx - sr, bodyTop - sr * 1.6f, scx + sr, bodyTop + sr * 0.4f), 180, 180, false, p);
            c.drawLine(scx - sr, bodyTop - sr * 0.6f, scx - sr, bodyTop, p);
            c.drawLine(scx + sr, bodyTop - sr * 0.6f, scx + sr, bodyTop, p);
            p.setStyle(android.graphics.Paint.Style.FILL);
            c.drawText("VPN", lx + lw + 4 * dp, cy - (p.ascent() + p.descent()) / 2f, p);
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
        if (h >= 23 || h < 5) return T.t("Доброй ночи");
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
                pill.setOnClickListener(v -> openInput(it));
                if (it.id.startsWith("tv:")) pill.setOnLongClickListener(v -> { chooseTvApp(); return true; });
                LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i > 0) ip.leftMargin = Ui.dp(this, 12);
                irow.addView(pill, ip);
            }
            ins.addView(irow);
            page.addView(ins);
        }
    }

    /**
     * Apps on the second screen: [appsTop] (the apps heading or their first row) is pushed just
     * below the bottom of the screen; with [favBottom] the favourites sit low on the first one.
     * Worked out from the views' places in the page on every layout, not once from screen
     * coordinates: those were taken before the page had settled (the weather line or the
     * art came in later) and the shelf sometimes jumped down «for no reason» (an owner's report).
     */
    private void pushBelow(final View favTop, final View favShelf, final View appsTop, final boolean favBottom) {
        if (appsTop == null) return;
        final int[] extra = {0, 0}; // added to favTop / appsTop top margins
        appsTop.getViewTreeObserver().addOnGlobalLayoutListener(
                new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
            @Override public void onGlobalLayout() {
                if (!appsTop.isAttachedToWindow()) {
                    appsTop.getViewTreeObserver().removeOnGlobalLayoutListener(this);
                    return;
                }
                ScrollView sc = scroll;
                int screenH = sc != null && sc.getHeight() > 0 ? sc.getHeight() : getResources().getDisplayMetrics().heightPixels;
                if (appsTop.getHeight() == 0) return;
                int fe = 0;
                if (favBottom && favTop != null && favShelf != null && favShelf.getHeight() > 0) {
                    int baseBottom = favShelf.getBottom() - extra[0];
                    fe = Math.max(0, screenH - Ui.dp(HomeActivity.this, 40) - baseBottom);
                }
                int baseTop = appsTop.getTop() - extra[0] - extra[1];
                int ae = Math.max(0, screenH + Ui.dp(HomeActivity.this, 26) - (baseTop + fe));
                if (Math.abs(fe - extra[0]) > 1 && favTop != null) {
                    LinearLayout.LayoutParams fl = (LinearLayout.LayoutParams) favTop.getLayoutParams();
                    fl.topMargin += fe - extra[0];
                    extra[0] = fe;
                    favTop.setLayoutParams(fl);
                }
                if (Math.abs(ae - extra[1]) > 1) {
                    LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) appsTop.getLayoutParams();
                    lp.topMargin += ae - extra[1];
                    extra[1] = ae;
                    appsTop.setLayoutParams(lp);
                }
            }
        });
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
        int sec = prefs.ambientSec();
        ambientAnim.setDuration(sec > 0 ? sec * 1000L : (prefs.anim() == Prefs.ANIM_SOFT ? 22000 : 14000));
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

    /** [squareTiles]: the dock and «Витрина» (icons look right there); wide tiles keep the
     *  TV banners unless the owner chose icons everywhere ([Prefs.icons]). Apps without a
     *  banner always get their own icon on a plate, never a tiny icon in an empty card. */
    private void loadArt(List<AppTile> tiles, boolean squareTiles) {
        final int mode = prefs.icons();
        final boolean small = mode == Prefs.ICONS_SMALL; // the icon at its own size on the card (review request)
        final boolean useIcons = small || mode == Prefs.ICONS_ON || (mode == Prefs.ICONS_AUTO && squareTiles);
        final boolean round = useIcons && prefs.iconShape() == Prefs.SHAPE_CIRCLE; // round icons (owners asked)
        for (final AppTile t : tiles) {
            final int cw = t.cardW(), ch = t.cardH();
            final String k = t.app.pkg + "#" + (small ? "s" : useIcons ? "i" : "b") + (round ? "o" : "") + cw + "x" + ch;
            Drawable cached = artCache.get(k);
            if (cached != null) {
                t.setArt(cached, Boolean.TRUE.equals(bannerCache.get(k)));
                if (round && !small) t.setRound(Boolean.TRUE.equals(bannerCache.get(k)));
                continue;
            }
            if (round) {
                io.execute(() -> {
                    Drawable icon = IconArt.icon(pm, t.app);
                    android.graphics.Bitmap b = small ? IconArt.circle(icon, Math.round(ch * 0.6f))
                            : IconArt.roundTile(icon, cw, ch);
                    final Drawable art = b == null ? icon : new android.graphics.drawable.BitmapDrawable(getResources(), b);
                    final boolean fills = !small && b != null;
                    main.post(() -> {
                        if (art == null) return;
                        artCache.put(k, art);
                        bannerCache.put(k, fills);
                        t.setArt(art, fills);
                        t.setRound(fills);
                    });
                });
                continue;
            }
            io.execute(() -> {
                Drawable d = useIcons ? null : t.app.loadBanner(pm);
                boolean banner = d != null;
                if (banner && !small) {
                    android.graphics.Bitmap fb = IconArt.banner(d, cw, ch);
                    if (fb != null) {
                        android.graphics.drawable.BitmapDrawable bd =
                                new android.graphics.drawable.BitmapDrawable(getResources(), fb);
                        bd.setFilterBitmap(true);
                        d = bd;
                    }
                }
                if (small) d = IconArt.icon(pm, t.app);
                if (d == null) {
                    android.graphics.Bitmap b = IconArt.tile(IconArt.icon(pm, t.app), t.app.loadBanner(pm), cw, ch);
                    if (b != null) {
                        android.graphics.drawable.BitmapDrawable bd =
                                new android.graphics.drawable.BitmapDrawable(getResources(), b);
                        bd.setFilterBitmap(true);
                        d = bd;
                        banner = true; // fills the card like a banner
                    }
                }
                if (d == null) d = t.app.loadIcon(pm);
                final Drawable art = d;
                final boolean fills = banner;
                main.post(() -> {
                    if (art == null) return;
                    artCache.put(k, art);
                    bannerCache.put(k, fills);
                    t.setArt(art, fills);
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

    private void showOptions(final AppTile t) {
        whenOkReleased(() -> { if (!isFinishing()) showOptionsNow(t); });
    }

    private void showOptionsNow(AppTile t) {
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
                .setCancelable(true)
                // Back always closes it, whatever the firmware's dialog does with the key (#15)
                .setOnKeyListener((d, code, ev) -> {
                    if (code == KeyEvent.KEYCODE_BACK && ev.getAction() == KeyEvent.ACTION_UP) {
                        d.dismiss();
                        return true;
                    }
                    return false;
                })
                .show();
    }
}
