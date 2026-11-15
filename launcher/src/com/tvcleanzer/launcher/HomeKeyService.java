package com.tvcleanzer.launcher;

import android.accessibilityservice.AccessibilityService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Keeps TVCleanzer Launcher as the home screen on firmwares that hard-wire
 * Home to their own launcher (same idea as HomeKey on Xiaomi):
 *  - Home key on the remote opens our launcher;
 *  - if the stock launcher pops up by itself (boot, wake, after HDMI) we
 *    replace it, unless the user opened it on purpose from our launcher.
 */
public class HomeKeyService extends AccessibilityService {
    /** Set by HomeActivity when the user starts the stock launcher from a tile. */
    static volatile String allowedStockPkg;

    private final Set<String> stockHomes = new HashSet<>();
    private long lastRedirect;
    private String lastPkg = "";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private BroadcastReceiver screenOn;

    /** Firmware screens that come up by themselves at power-on or wake, outside the HOME
     *  role: Xiaomi PatchWall (BannerLogoB), Yandex and Sber homes, Google launchers. */
    static final Set<String> HIJACKERS = new HashSet<>(Arrays.asList(
            "com.mitv.tvhome.atv", "com.mitv.tvhome", "com.google.android.tvlauncher",
            "com.google.android.apps.tv.launcherx", "com.google.android.leanbacklauncher",
            "com.yandex.tv.home", "ru.sberdevices.starlauncher"));

    /** The first minutes after boot: the stock home is often on screen before Android binds us. */
    static final long BOOT_WINDOW_MS = 3 * 60 * 1000L;

    @Override
    protected void onServiceConnected() {
        refreshStockHomes();
        if (SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) checkFrontSoon();
        screenOn = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) {
                refreshStockHomes();
                Prefs p = new Prefs(HomeKeyService.this);
                final String auto = p.autostart();
                if (!auto.isEmpty() && !p.kids()) {
                    // the TV woke up: the app chosen to start with the TV, unless a key comes first
                    lastKeyAt = 0;
                    final long armed = SystemClock.uptimeMillis();
                    handler.postDelayed(() -> {
                        if (lastKeyAt <= armed) HomeActivity.openAutostart(HomeKeyService.this, auto);
                    }, 2500);
                } else {
                    checkFrontSoon();
                }
            }
        };
        try { registerReceiver(screenOn, new IntentFilter(Intent.ACTION_SCREEN_ON)); } catch (Throwable ignored) {}
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (screenOn != null) try { unregisterReceiver(screenOn); } catch (Throwable ignored) {}
        super.onDestroy();
    }

    /** Power-on / wake: if a stock screen is in front, replace it (a few tries: firmwares
     *  bring their home up at different moments). A key press in between wins. */
    private void checkFrontSoon() {
        lastKeyAt = 0;
        final long armed = SystemClock.uptimeMillis();
        for (long d : new long[]{1500, 4000, 9000, 15000}) {
            handler.postDelayed(() -> {
                if (lastKeyAt > armed) return; // the user is already doing something
                String pkg = frontPackage();
                if (pkg != null && isStock(pkg) && !pkg.equals(allowedStockPkg)) openHome();
            }, d);
        }
    }

    private long lastKeyAt;

    private String frontPackage() {
        try {
            AccessibilityNodeInfo root = getRootInActiveWindow();
            if (root == null) return null;
            CharSequence p = root.getPackageName();
            return p == null ? null : p.toString();
        } catch (Throwable t) {
            return null;
        }
    }

    private boolean isStock(String pkg) {
        return !pkg.equals(getPackageName()) && (stockHomes.contains(pkg) || HIJACKERS.contains(pkg));
    }

    private void refreshStockHomes() {
        stockHomes.clear();
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        try {
            List<ResolveInfo> list = getPackageManager()
                    .queryIntentActivities(home, PackageManager.MATCH_DEFAULT_ONLY);
            for (ResolveInfo ri : list) {
                String p = ri.activityInfo.packageName;
                // "android" = chooser, Settings has a fallback home on some TVs
                if (!p.equals(getPackageName()) && !p.equals("android")
                        && !p.equals("com.android.settings") && !p.equals("com.android.tv.settings")) {
                    stockHomes.add(p);
                }
            }
        } catch (Throwable ignored) {}
    }

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        int code = e.getKeyCode();
        lastKeyAt = SystemClock.uptimeMillis();
        // 191 = the "Mi" button on Xiaomi remotes (elsewhere it is a gamepad key)
        boolean miKey = code == 191 && android.os.Build.MANUFACTURER.toLowerCase().contains("xiaomi");
        if (code != KeyEvent.KEYCODE_HOME && !miKey) return false;
        if (e.getAction() == KeyEvent.ACTION_UP) {
            allowedStockPkg = null;
            openHome();
        }
        return true; // consume both down and up
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null || event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return;
        CharSequence cs = event.getPackageName();
        if (cs == null) return;
        String pkg = cs.toString();
        boolean wasSame = pkg.equals(lastPkg);
        lastPkg = pkg;

        if (!isStock(pkg)) {
            if (!pkg.equals(getPackageName()) && !pkg.equals("android")) allowedStockPkg = null;
            return;
        }
        if (pkg.equals(allowedStockPkg) || wasSame) return; // user is in it on purpose
        if (SystemClock.uptimeMillis() - lastRedirect < 1500) return; // loop guard
        openHome();
    }

    private void openHome() {
        lastRedirect = SystemClock.uptimeMillis();
        Intent i = new Intent(this, HomeActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try { startActivity(i); } catch (Throwable ignored) {}
    }

    @Override
    public void onInterrupt() {}
}
