package com.tvcleanzer.launcher;

import android.accessibilityservice.AccessibilityService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.media.AudioManager;
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

    /** The running instance, for ConfigReceiver (key filter switched from the phone). */
    static volatile HomeKeyService running;

    /** «Кнопки пульта»: KeyMapActivity waits for one press of the button to assign. */
    interface KeyLearn { void key(int code); }
    static volatile KeyLearn learn;
    /** Remote keys that open an app (Prefs.keyMap), cached for the key path. */
    private static volatile java.util.Map<Integer, String> keyMap = new java.util.HashMap<>();

    /** Navigation, volume, power and digits stay what they are. */
    static boolean remappable(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_UP: case KeyEvent.KEYCODE_DPAD_DOWN: case KeyEvent.KEYCODE_DPAD_LEFT:
            case KeyEvent.KEYCODE_DPAD_RIGHT: case KeyEvent.KEYCODE_DPAD_CENTER: case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_BACK: case KeyEvent.KEYCODE_HOME: case KeyEvent.KEYCODE_VOLUME_UP:
            case KeyEvent.KEYCODE_VOLUME_DOWN: case KeyEvent.KEYCODE_VOLUME_MUTE: case KeyEvent.KEYCODE_MUTE:
            case KeyEvent.KEYCODE_POWER: case KeyEvent.KEYCODE_SLEEP: case KeyEvent.KEYCODE_WAKEUP:
            case KeyEvent.KEYCODE_TV_POWER: case KeyEvent.KEYCODE_UNKNOWN:
                return false;
            default:
                return !(code >= KeyEvent.KEYCODE_0 && code <= KeyEvent.KEYCODE_9);
        }
    }

    /** Catch keys only where the phone app found it needed (Prefs.keyFilter): where Home opens
     *  us by itself the filter only costs key repeat. The redirect of a stock screen that pops
     *  up at power-on works without it. */
    void updateKeyFilter() {
        try {
            android.accessibilityservice.AccessibilityServiceInfo info = getServiceInfo();
            if (info == null) return;
            int flag = android.accessibilityservice.AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS;
            Prefs p = new Prefs(this);
            keyMap = p.keyMap();
            boolean want = !keyMap.isEmpty() || learn != null || volumeFiltered(this, p);
            int nf = want ? info.flags | flag : info.flags & ~flag;
            if (nf != info.flags) {
                info.flags = nf;
                setServiceInfo(info);
            }
        } catch (Throwable ignored) {}
    }

    /** Would the filter be on for Home / ⚙ / Source alone (remote-key mapping aside)? Then held
     *  Volume moves one step. The owner's choice in the settings wins. Not chosen: smooth, except
     *  where catching keys is the only way something works —
     *   · Yandex / Sber homes (Alice, Salute): only a seen Home press lets us replace them;
     *   · Google TV with its home switched off: nobody else answers ⚙, TV and Source;
     *   · Google TV with its home on: Home itself (see googleTvHomeOn).
     *  Xiaomi is smooth in any case (0.56: most complaints; Google TV models included).
     *  Owners on Haier MatrixTV, Sony Bravia, DEXP, Xiaomi asked for it in the chat. */
    static boolean volumeFiltered(Context c, Prefs p) {
        if (p.volSmoothSet()) return !p.volSmooth() && (p.keyFilter() || stockHomeOff(c));
        if (Prefs.xiaomi()) return false;
        return featureHomeOn(c) || stockHomeOff(c) || googleTvHomeOn(c);
    }

    /** Google TV with its home on: the HOME role never sticks to us there and the window path
     *  missed launcherx (TCL 43V6C, Android 12, 0.63: «скидывает на стоковый», service bound) —
     *  only a caught Home press opens us. */
    static boolean googleTvHomeOn(Context c) {
        try {
            return c.getPackageManager().getApplicationInfo("com.google.android.apps.tv.launcherx", 0).enabled;
        } catch (Throwable t) {
            return false;
        }
    }

    /** Yandex TV / Sber home installed and on. */
    static boolean featureHomeOn(Context c) {
        for (String p : FEATURE_HOMES) {
            try {
                if (c.getPackageManager().getApplicationInfo(p, 0).enabled) return true;
            } catch (Throwable ignored) {}
        }
        return false;
    }

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
            "com.yandex.tv.home", "ru.sberdevices.starlauncher", "com.tcl.waterfall.overseas"));

    /** Homes that also host the TV's own features (Alice search, Sber assistant, Google TV
     *  search): replaced only right after Home / power-on / wake, never while the owner uses them.
     *  (Google TV's launcherx stays out: there it is the real home that Back returns to.) */
    static final Set<String> FEATURE_HOMES = new HashSet<>(Arrays.asList(
            "com.yandex.tv.home", "ru.sberdevices.starlauncher"));

    /** Until when a stock home that pops up is replaced without asking (uptime ms). Yandex TV
     *  starts its home a second or two AFTER ours on Home, and late after power-on. */
    private long armedUntil;
    private int armedRedirects;

    private void arm(long ms) {
        armedUntil = SystemClock.uptimeMillis() + ms;
        armedRedirects = 0;
    }

    private boolean armed() { return SystemClock.uptimeMillis() < armedUntil; }

    /** The first minutes after boot: the stock home is often on screen before Android binds us. */
    static final long BOOT_WINDOW_MS = 3 * 60 * 1000L;

    @Override
    protected void onServiceConnected() {
        running = this;
        updateKeyFilter();
        updateNight();
        refreshStockHomes();
        if (SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) { arm(90_000); checkFrontSoon(); }
        screenOn = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) {
                refreshStockHomes();
                arm(60_000);
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
        if (running == this) running = null;
        handler.removeCallbacksAndMessages(null);
        removeNight();
        if (screenOn != null) try { unregisterReceiver(screenOn); } catch (Throwable ignored) {}
        super.onDestroy();
    }

    /** Power-on / wake: if a stock screen is in front, replace it (a few tries: firmwares
     *  bring their home up at different moments). A key press in between wins. */
    private void checkFrontSoon() {
        lastKeyAt = 0;
        final long armed = SystemClock.uptimeMillis();
        for (long d : new long[]{1500, 4000, 9000, 15000, 25000, 40000}) {
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
        return !pkg.equals(getPackageName()) && !tvPlayers.contains(pkg)
                && (stockHomes.contains(pkg) || HIJACKERS.contains(pkg));
    }

    /** Apps that show HDMI / live TV. Some firmwares (TCL) let their TV player answer HOME too:
     *  we took it for the stock home and threw the owner back from every input (TCL C7L,
     *  Smart TV Pro: «источник включается и сразу летит в лаунчер»). Never replaced. */
    private final Set<String> tvPlayers = new HashSet<>();

    /** The HOME activities of the stock launchers. Google TV draws its Inputs and Settings
     *  panels from the same package: only its home screen itself is replaced. */
    private final Set<String> homeClasses = new HashSet<>();

    /** Launchers whose other screens (panels, dialogs) belong to the TV, not to the home. */
    static final Set<String> CLASS_STRICT = new HashSet<>(Arrays.asList(
            "com.google.android.apps.tv.launcherx", "com.google.android.tvlauncher",
            "com.google.android.leanbacklauncher", "com.tcl.waterfall.overseas"));

    /** Opening an input from our launcher: leave whatever comes up for a while (HDMI apps
     *  start through a chain of screens). Uptime ms. */
    static volatile long quietUntil;

    static void quiet(long ms) { quietUntil = SystemClock.uptimeMillis() + ms; }

    private void refreshTvPlayers() {
        tvPlayers.clear();
        PackageManager pm = getPackageManager();
        Intent[] probes = {
                new Intent(Intent.ACTION_VIEW, android.media.tv.TvContract.buildChannelUriForPassthroughInput("x")),
                new Intent(Intent.ACTION_VIEW).setDataAndType(android.media.tv.TvContract.buildChannelUri(1),
                        android.media.tv.TvContract.Channels.CONTENT_ITEM_TYPE),
        };
        for (Intent probe : probes) {
            try {
                for (ResolveInfo ri : pm.queryIntentActivities(probe, 0)) tvPlayers.add(ri.activityInfo.packageName);
            } catch (Throwable ignored) {}
        }
        tvPlayers.addAll(Arrays.asList("com.tcl.tv", "com.tcl.sourcemenu", "com.android.tv", "com.google.android.tv",
                "com.mediatek.wwtv.tvcenter", "com.droidlogic.tvsource", "com.xiaomi.mitv.tvplayer",
                "org.droidtv.playtv", "com.sony.dtv.tvx"));
        tvPlayers.remove(getPackageName());
    }

    private void refreshStockHomes() {
        refreshTvPlayers();
        stockHomes.clear();
        homeClasses.clear();
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
                    homeClasses.add(ri.activityInfo.name);
                    if (ri.activityInfo.targetActivity != null) homeClasses.add(ri.activityInfo.targetActivity);
                }
            }
        } catch (Throwable ignored) {}
        // in case the system hides them from the HOME query (package visibility)
        homeClasses.add("com.google.android.apps.tv.launcherx.home.HomeActivity");
    }

    private int lastKeyCode;

    /** Keys that don't ask for a screen of their own: moving around, OK, Back, volume. Any other
     *  key (Settings, TV, Input, Guide, the firmware's own buttons) opens something on purpose,
     *  and on Google TV that something is often a panel of the stock home itself. */
    private static boolean plainKey(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_UP: case KeyEvent.KEYCODE_DPAD_DOWN:
            case KeyEvent.KEYCODE_DPAD_LEFT: case KeyEvent.KEYCODE_DPAD_RIGHT:
            case KeyEvent.KEYCODE_DPAD_CENTER: case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_BACK: case KeyEvent.KEYCODE_ESCAPE: case KeyEvent.KEYCODE_HOME:
            case KeyEvent.KEYCODE_VOLUME_UP: case KeyEvent.KEYCODE_VOLUME_DOWN:
            case KeyEvent.KEYCODE_VOLUME_MUTE: case KeyEvent.KEYCODE_MUTE:
            case KeyEvent.KEYCODE_POWER: case KeyEvent.KEYCODE_SLEEP: case KeyEvent.KEYCODE_WAKEUP:
                return true;
            default:
                return false;
        }
    }

    /** A stock screen that comes up within moments of such a key was asked for: leave it. */
    private boolean keyAsked() {
        return !plainKey(lastKeyCode) && SystemClock.uptimeMillis() - lastKeyAt < 2500;
    }

    /** With the stock home switched off (pinned on Google TV) nobody answers the remote's
     *  Settings and TV keys any more: we do. */
    private boolean stockKey(KeyEvent e) {
        int code = e.getKeyCode();
        if (code != KeyEvent.KEYCODE_SETTINGS && code != KeyEvent.KEYCODE_TV && code != KeyEvent.KEYCODE_TV_INPUT) return false;
        if (!new Prefs(this).stockOff() && !stockHomeOff(this)) return false;
        if (e.getAction() == KeyEvent.ACTION_UP) {
            Intent i = null;
            if (code == KeyEvent.KEYCODE_SETTINGS) {
                i = new Intent(android.provider.Settings.ACTION_SETTINGS);
            } else if (code == KeyEvent.KEYCODE_TV_INPUT) {
                // the stock home drew the input list: now ours does
                i = new Intent(this, HomeActivity.class).putExtra(HomeActivity.EXTRA_INPUTS, true);
            } else {
                Inputs.Item tv = Inputs.tv(this, true);
                if (tv == null) return false;
                quiet(15000);
                Inputs.open(this, tv);
                return true;
            }
            if (i == null) return false;
            try { startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); } catch (Throwable ignored) {}
        }
        return true;
    }

    /** Google TV's home is switched off (pinned hard, or by hand): nobody else answers ⚙,
     *  TV and Source any more (TCL C7L owner: ⚙ dead after bringing the stock home back and forth). */
    static boolean stockHomeOff(Context c) {
        PackageManager pm = c.getPackageManager();
        boolean any = false;
        for (String p : new String[]{"com.google.android.apps.tv.launcherx", "com.google.android.tvlauncher"}) {
            try {
                android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(p, 0);
                any = true;
                if (ai.enabled) return false;
            } catch (Throwable ignored) {}
        }
        return any;
    }

    private Runnable volRepeat;

    private void stopVolRepeat() {
        if (volRepeat != null) handler.removeCallbacks(volRepeat);
        volRepeat = null;
    }

    /** Holding Volume with our key filter on moved the level one step only (Xiaomi MOEU1, Haier
     *  FF Pro: fine while the service was not running, broken again once it was). The remote's
     *  own repeats reach us as DOWN with repeatCount > 0 but go no further once filtered; 0.28
     *  stepped aside for them and nothing happened. Now every repeat is a volume step made here,
     *  and if a remote sends no repeats at all we keep stepping while the key is held.
     *  Check on a TV: logcat -d -s TVCleanzerVol */
    private boolean volumeKey(KeyEvent e) {
        int code = e.getKeyCode();
        if (code != KeyEvent.KEYCODE_VOLUME_UP && code != KeyEvent.KEYCODE_VOLUME_DOWN) return false;
        final int dir = code == KeyEvent.KEYCODE_VOLUME_UP ? AudioManager.ADJUST_RAISE : AudioManager.ADJUST_LOWER;
        if (e.getAction() == KeyEvent.ACTION_UP) {
            stopVolRepeat();
            return false;
        }
        if (e.getAction() != KeyEvent.ACTION_DOWN) return false;
        if (e.getRepeatCount() > 0) {
            stopVolRepeat(); // the remote repeats by itself: one step per repeat
            if (e.getRepeatCount() == 1) android.util.Log.i("TVCleanzerVol", "remote repeats");
            volumeStep(dir);
            return true;
        }
        stopVolRepeat();
        volRepeat = new Runnable() {
            int steps;
            @Override public void run() {
                if (++steps > 100) { stopVolRepeat(); return; } // the UP got lost: don't run away
                if (steps == 1) android.util.Log.i("TVCleanzerVol", "no repeats from the remote: stepping");
                volumeStep(dir);
                handler.postDelayed(this, 110);
            }
        };
        // 600 ms, not 450: a slow remote's UP came after the first step (Dmitry: 2–3 steps a press)
        handler.postDelayed(volRepeat, 600);
        return false;
    }

    private void volumeStep(int dir) {
        try {
            AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
            if (am != null) am.adjustSuggestedStreamVolume(dir, AudioManager.USE_DEFAULT_STREAM_TYPE,
                    AudioManager.FLAG_SHOW_UI);
        } catch (Throwable t) {
            android.util.Log.w("TVCleanzerVol", "step failed: " + t);
        }
    }

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        int code = e.getKeyCode();
        lastKeyAt = SystemClock.uptimeMillis();
        lastKeyCode = code;
        KeyLearn l = learn;
        if (l != null && remappable(code)) {
            if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) l.key(code);
            return true;
        }
        String app = keyMap.get(code);
        if (app != null) {
            if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) {
                try {
                    android.content.Intent i = getPackageManager().getLeanbackLaunchIntentForPackage(app);
                    if (i == null) i = getPackageManager().getLaunchIntentForPackage(app);
                    if (i != null) startActivity(i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK));
                } catch (Throwable ignored) {}
            }
            return true;
        }
        if (volumeKey(e)) return true;
        if (stockKey(e)) return true;
        // 191 = the "Mi" button on Xiaomi remotes (elsewhere it is a gamepad key)
        boolean miKey = code == 191 && android.os.Build.MANUFACTURER.toLowerCase().contains("xiaomi");
        if (code != KeyEvent.KEYCODE_HOME && !miKey) {
            // the owner picked something (OK, Alice / voice key): leave the stock screens alone
            if (e.getAction() == KeyEvent.ACTION_DOWN && (code == KeyEvent.KEYCODE_DPAD_CENTER
                    || code == KeyEvent.KEYCODE_ENTER || code == KeyEvent.KEYCODE_SEARCH
                    || code == KeyEvent.KEYCODE_VOICE_ASSIST || code == KeyEvent.KEYCODE_ASSIST)) {
                armedUntil = 0;
            }
            return false;
        }
        // Home held down = running apps too (a chat wish, together with the double press)
        if (code == KeyEvent.KEYCODE_HOME && e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 1) {
            homeHeld = true;
            lastHomeUp = 0;
            armedUntil = 0;
            recentsAt = SystemClock.uptimeMillis();
            if (!recents()) openHome();
            return true;
        }
        if (code == KeyEvent.KEYCODE_HOME && e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) {
            homeHeld = false;
        }
        if (e.getAction() == KeyEvent.ACTION_UP && homeHeld && code == KeyEvent.KEYCODE_HOME) {
            homeHeld = false;
            return true; // the hold already opened running apps
        }
        if (e.getAction() == KeyEvent.ACTION_UP) {
            long now = SystemClock.uptimeMillis();
            if (code == KeyEvent.KEYCODE_HOME && now - lastHomeUp < DOUBLE_HOME_MS) {
                // Home twice = running apps, as the stock firmware does. We take Home for
                // ourselves, so the system never saw the second press (Homatics Box 4K owner:
                // worked from the phone's remote, not from the real one).
                lastHomeUp = 0;
                armedUntil = 0;
                recentsAt = now;
                if (!recents()) openHome();
                return true;
            }
            lastHomeUp = code == KeyEvent.KEYCODE_HOME ? now : 0;
            allowedStockPkg = null;
            arm(8000);
            openHome();
        }
        return true; // consume both down and up
    }

    private static final long DOUBLE_HOME_MS = 450;
    private boolean homeHeld;
    private long lastHomeUp;
    /** On Google TV the running-apps panel belongs to the stock home: don't replace it. */
    private long recentsAt;

    /** Our own «Запущенные» row when the phone gave us usage access (many TVs have no recents
     *  screen at all), else the system's; false where neither exists. */
    private boolean recents() {
        if (usageAccess(this)) {
            try {
                startActivity(new Intent(this, RecentsActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                return true;
            } catch (Throwable ignored) {}
        }
        try {
            return performGlobalAction(GLOBAL_ACTION_RECENTS);
        } catch (Throwable t) {
            return false;
        }
    }

    // ── Night mode: a warm, dimmer veil over everything (no root needed: an accessibility
    //    overlay sits above every app). Owners asked for it like Night Shift, 1–5, by time. ──

    private android.view.View nightView;
    private int nightShown = -1;
    private final Runnable nightTick = new Runnable() {
        @Override public void run() { updateNight(); }
    };

    /** Shows, changes or removes the veil to match the settings and the clock. */
    void updateNight() {
        handler.removeCallbacks(nightTick);
        Prefs p = new Prefs(this);
        int level = p.nightNow() ? p.nightLevel() : 0;
        if (level != nightShown) {
            removeNight();
            if (level > 0) addNight(level);
        }
        if (p.nightMode() == Prefs.NIGHT_SCHEDULE) handler.postDelayed(nightTick, 30_000);
    }

    private void addNight(int level) {
        if (android.os.Build.VERSION.SDK_INT < 22) return; // no accessibility overlay before 5.1
        try {
            android.view.WindowManager wm = (android.view.WindowManager) getSystemService(WINDOW_SERVICE);
            android.view.View v = new android.view.View(this);
            // warm amber over a little black: blue goes down first, brightness with it
            float a = level / 5f;
            int amber = Math.round(a * 0.30f * 255) << 24 | 0xFF8A1E;
            int dark = Math.round(a * 0.40f * 255) << 24;
            v.setBackground(new android.graphics.drawable.LayerDrawable(new android.graphics.drawable.Drawable[]{
                    new android.graphics.drawable.ColorDrawable(dark),
                    new android.graphics.drawable.ColorDrawable(amber)}));
            android.view.WindowManager.LayoutParams lp = new android.view.WindowManager.LayoutParams(
                    android.view.WindowManager.LayoutParams.MATCH_PARENT,
                    android.view.WindowManager.LayoutParams.MATCH_PARENT,
                    android.view.WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | android.view.WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | android.view.WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    android.graphics.PixelFormat.TRANSLUCENT);
            wm.addView(v, lp);
            nightView = v;
            nightShown = level;
        } catch (Throwable t) {
            android.util.Log.w("TVCleanzerNight", "overlay: " + t);
            nightShown = 0;
        }
    }

    private void removeNight() {
        if (nightView != null) {
            try { ((android.view.WindowManager) getSystemService(WINDOW_SERVICE)).removeView(nightView); } catch (Throwable ignored) {}
            nightView = null;
        }
        nightShown = 0;
    }

    static boolean usageAccess(Context c) {
        if (android.os.Build.VERSION.SDK_INT < 22) return false;
        try {
            android.app.AppOpsManager ops = (android.app.AppOpsManager) c.getSystemService(Context.APP_OPS_SERVICE);
            @SuppressWarnings("deprecation")
            int mode = ops.checkOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                    android.os.Process.myUid(), c.getPackageName());
            return mode == android.app.AppOpsManager.MODE_ALLOWED;
        } catch (Throwable t) {
            return false;
        }
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
        if (pkg.equals(allowedStockPkg)) return; // opened from our launcher on purpose
        if (SystemClock.uptimeMillis() < quietUntil) return; // an input / TV just opened from us
        if (CLASS_STRICT.contains(pkg)) {
            // Google TV: its Inputs / Settings panels are this package too; only its home screen goes
            CharSequence cls = event.getClassName();
            if (cls == null || !homeClasses.contains(cls.toString())) return;
        }
        if (SystemClock.uptimeMillis() - recentsAt < 4000) return; // Home twice: running apps
        // Settings / TV / Input key: Google TV draws these panels from its own home (TCL owners
        // lost both buttons because we kept replacing that home)
        if (keyAsked()) return;
        if (armed()) {
            // right after Home / power-on: the firmware put its screen over ours
            if (armedRedirects >= 6) return; // it keeps fighting: give up rather than loop
            armedRedirects++;
            long since = SystemClock.uptimeMillis() - lastRedirect;
            if (since < 1200) {
                handler.postDelayed(() -> {
                    String now = frontPackage();
                    if (now != null && isStock(now) && !now.equals(allowedStockPkg)) openHome();
                }, 1300 - since);
            } else {
                openHome();
            }
            return;
        }
        if (FEATURE_HOMES.contains(pkg) || wasSame) return; // the owner is using it (Alice search…)
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
