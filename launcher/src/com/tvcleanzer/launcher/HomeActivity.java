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
    private static final int GRID_COLUMNS = 6;
    private static final int FAV_VISIBLE = 4;

    private Prefs prefs;
    private PackageManager pm;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Map<String, Drawable> artCache = new HashMap<>();
    private final Map<String, Boolean> bannerCache = new HashMap<>();
    private List<AppEntry> apps = new ArrayList<>();
    private List<AppEntry> favorites = new ArrayList<>();
    private final Set<String> homeApps = new java.util.HashSet<>();

    private FrameLayout root;
    private ScrollView scroll;
    private boolean resumed, dirty;

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
        setContentView(root);
        root.setBackground(Ui.background(prefs.skin()));

        prefs.sp.registerOnSharedPreferenceChangeListener(this);
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addDataScheme("package");
        registerReceiver(packages, f);
        reloadApps();
    }

    @Override
    protected void onDestroy() {
        prefs.sp.unregisterOnSharedPreferenceChangeListener(this);
        try { unregisterReceiver(packages); } catch (Exception ignored) {}
        io.shutdownNow();
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        if (dirty) { dirty = false; build(); }
    }

    @Override
    protected void onPause() {
        resumed = false;
        super.onPause();
    }

    @Override
    public void onSharedPreferenceChanged(SharedPreferences sp, String key) {
        // Settings screen or the phone app changed something.
        if (resumed) main.post(this::build); else dirty = true;
    }

    /** Home must never close itself; Back jumps to the top instead. */
    @Override
    public void onBackPressed() {
        if (scroll != null && scroll.getScrollY() > 0) {
            scroll.smoothScrollTo(0, 0);
            focusFirst();
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent e) {
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            View f = getCurrentFocus();
            if (f instanceof AppTile) { showOptions((AppTile) f); return true; }
        }
        return super.onKeyDown(keyCode, e);
    }

    // ── Data ────────────────────────────────────────────────────────────────

    private void reloadApps() {
        io.execute(() -> {
            final List<AppEntry> list = AppEntry.loadAll(this);
            final Set<String> homes = new java.util.HashSet<>();
            try {
                for (android.content.pm.ResolveInfo ri : pm.queryIntentActivities(
                        new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)) {
                    homes.add(ri.activityInfo.packageName);
                }
            } catch (Throwable ignored) {}
            main.post(() -> {
                apps = list;
                homeApps.clear();
                homeApps.addAll(homes);
                build();
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
        favorites = resolveFavorites(hidden);

        int screenW = getResources().getDisplayMetrics().widthPixels;
        int padH = Math.round(screenW * 0.05f);          // TV overscan-safe margin
        int padV = Math.round(screenW * 0.03f);
        int gap = Ui.dp(this, 22);
        int contentW = screenW - 2 * padH;
        int favW = (contentW - 2 * Ui.dp(this, 22) - gap * (FAV_VISIBLE - 1)) / FAV_VISIBLE;
        int favH = favW * 9 / 16;
        int tileW = (contentW - gap * (GRID_COLUMNS - 1)) / GRID_COLUMNS;
        int tileH = tileW * 9 / 16;

        root.removeAllViews();
        root.setBackground(Ui.background(skin));

        // Accent glow in the top-right corner
        View glow = new View(this);
        int gs = Math.round(screenW * 0.7f);
        glow.setBackground(Ui.glow(skin.accent, gs / 2f));
        FrameLayout.LayoutParams glp = new FrameLayout.LayoutParams(gs, gs, Gravity.TOP | Gravity.END);
        glp.topMargin = -gs / 2;
        glp.rightMargin = -gs / 3;
        root.addView(glow, glp);
        View vig = new View(this);
        vig.setBackground(Ui.vignette());
        root.addView(vig, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        scroll = new ScrollView(this);
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

        List<AppTile> tiles = new ArrayList<>();
        if (!favorites.isEmpty()) {
            page.addView(sectionTitle("Избранное", Ui.dp(this, 30)));
            FrameLayout shelf = new FrameLayout(this);
            shelf.setBackground(Ui.glass(Ui.dp(this, 30)));
            shelf.setClipChildren(true);
            LinearLayout.LayoutParams shp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            shp.topMargin = Ui.dp(this, 12);
            HorizontalScrollView hs = new HorizontalScrollView(this);
            hs.setClipChildren(true);
            hs.setClipToPadding(false);
            hs.setHorizontalScrollBarEnabled(false);
            hs.setOverScrollMode(View.OVER_SCROLL_NEVER);
            int inset = Ui.dp(this, 22);
            hs.setPadding(inset, Ui.dp(this, 18), inset, Ui.dp(this, 10));
            LinearLayout row = row();
            for (int i = 0; i < favorites.size(); i++) {
                AppTile t = tile(favorites.get(i), favW, favH, skin, labelsAlways, 15, 1.08f);
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

        List<AppEntry> rest = new ArrayList<>();
        for (AppEntry a : apps) if (!favorites.contains(a) && !hidden.contains(a.pkg)) rest.add(a);
        if (!rest.isEmpty()) {
            page.addView(sectionTitle("Приложения", Ui.dp(this, 26)));
            LinearLayout row = null;
            for (int i = 0; i < rest.size(); i++) {
                if (i % GRID_COLUMNS == 0) {
                    row = row();
                    row.setPadding(0, Ui.dp(this, 12), 0, Ui.dp(this, 4));
                    page.addView(row);
                }
                AppTile t = tile(rest.get(i), tileW, tileH, skin, labelsAlways, 13, 1.12f);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i % GRID_COLUMNS > 0) lp.leftMargin = gap;
                row.addView(t, lp);
                tiles.add(t);
            }
        }

        if (apps.isEmpty()) {
            TextView empty = Ui.text(this, 18, 0x99FFFFFF, "sans-serif");
            empty.setText("Загружаем приложения…");
            page.addView(empty);
        }

        root.addView(scroll, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // Restore focus to the same app, otherwise the first favourite.
        AppTile target = null;
        for (AppTile t : tiles) if (t.app.pkg.equals(focusPkg)) { target = t; break; }
        if (target == null && !tiles.isEmpty()) target = tiles.get(0);
        if (target != null) target.requestFocus();

        loadArt(tiles);
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
        left.addView(greet);

        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        timeRow.setGravity(Gravity.CENTER_VERTICAL);
        TextClock clock = new TextClock(this);
        String fmt = prefs.clock24() ? "HH:mm" : "h:mm";
        clock.setFormat24Hour(fmt);
        clock.setFormat12Hour(fmt);
        clock.setTextSize(64);
        clock.setTextColor(0xFFFFFFFF);
        clock.setIncludeFontPadding(false);
        clock.setLetterSpacing(-0.02f);
        clock.setTypeface(android.graphics.Typeface.create("sans-serif-thin", android.graphics.Typeface.NORMAL));
        timeRow.addView(clock);

        View divider = new View(this);
        divider.setBackgroundColor(0x40FFFFFF);
        LinearLayout.LayoutParams dvp = new LinearLayout.LayoutParams(Ui.dp(this, 1), Ui.dp(this, 44));
        dvp.leftMargin = Ui.dp(this, 20);
        dvp.rightMargin = Ui.dp(this, 20);
        timeRow.addView(divider, dvp);

        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE\nd MMMM");
        date.setFormat24Hour("EEEE\nd MMMM");
        date.setAllCaps(true);
        date.setLetterSpacing(0.12f);
        date.setTextSize(15);
        date.setLineSpacing(Ui.dp(this, 4), 1f);
        date.setTextColor(0xB3FFFFFF);
        timeRow.addView(date);
        LinearLayout.LayoutParams trp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        trp.topMargin = Ui.dp(this, 4);
        left.addView(timeRow, trp);
        bar.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Pill net = new Pill(this, networkLabel());
        net.setOnClickListener(v -> openSettings(Settings.ACTION_WIFI_SETTINGS));
        bar.addView(net);

        Pill tvSettings = new Pill(this, "Настройки ТВ");
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

    @SuppressWarnings("deprecation")
    private String networkLabel() {
        try {
            android.net.ConnectivityManager cm =
                    (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            android.net.NetworkInfo ni = cm == null ? null : cm.getActiveNetworkInfo();
            if (ni == null || !ni.isConnected()) return "Нет сети";
            if (ni.getType() == android.net.ConnectivityManager.TYPE_ETHERNET) return "Ethernet";
            if (ni.getType() == android.net.ConnectivityManager.TYPE_WIFI) return "Wi-Fi";
            return "В сети";
        } catch (Throwable t) {
            return "Сеть";
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
        if (h < 5) return "Доброй ночи";
        if (h < 12) return "Доброе утро";
        if (h < 18) return "Добрый день";
        return "Добрый вечер";
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

    private AppTile tile(AppEntry a, int w, int h, Skin skin, boolean labelsAlways, float sp, float scale) {
        AppTile t = new AppTile(this, a, w, h, skin, labelsAlways, sp, scale);
        t.setOnClickListener(v -> launch(a));
        t.setOnLongClickListener(v -> { showOptions(t); return true; });
        return t;
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
            Toast.makeText(this, "Не удалось открыть " + a.label, Toast.LENGTH_SHORT).show();
        }
    }

    // ── Long-press / Menu: edit favourites, hide, app info ─────────────────

    private void showOptions(AppTile t) {
        final AppEntry a = t.app;
        final boolean fav = favorites.contains(a);
        final List<String> items = new ArrayList<>();
        items.add(fav ? "Убрать из избранного" : "Добавить в избранное");
        if (fav) { items.add("Переместить левее"); items.add("Переместить правее"); }
        items.add("Скрыть с главного экрана");
        items.add("О приложении");

        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(a.label)
                .setItems(items.toArray(new String[0]), (d, which) -> {
                    String choice = items.get(which);
                    List<AppEntry> favs = new ArrayList<>(favorites);
                    int i = favs.indexOf(a);
                    switch (choice) {
                        case "Убрать из избранного": favs.remove(a); saveFavorites(favs); break;
                        case "Добавить в избранное": favs.add(a); saveFavorites(favs); break;
                        case "Переместить левее":
                            if (i > 0) { favs.remove(i); favs.add(i - 1, a); saveFavorites(favs); }
                            break;
                        case "Переместить правее":
                            if (i >= 0 && i < favs.size() - 1) { favs.remove(i); favs.add(i + 1, a); saveFavorites(favs); }
                            break;
                        case "Скрыть с главного экрана": {
                            Set<String> h = prefs.hidden();
                            h.add(a.pkg);
                            favs.remove(a);
                            saveFavorites(favs);
                            prefs.setHidden(h);
                            break;
                        }
                        case "О приложении":
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
