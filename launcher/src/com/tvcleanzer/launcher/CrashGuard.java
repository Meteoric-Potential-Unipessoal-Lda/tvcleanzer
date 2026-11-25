package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;

import java.util.ArrayList;
import java.util.List;

/**
 * 1.43: a home screen that crashes as it opens must never hold the TV in a loop (the idea is from
 * couch-tv, github.com/Seagey/couch-tv, MIT, CrashGuard.kt). Written down at once, so they survive
 * the process dying: every start of the home that neither lived 20 s nor closed normally, and
 * every uncaught exception. Two within 3 minutes and the launcher stands aside for 5: the home
 * opens the TV's own home instead, and the Home-key service and HomeWatch stop pulling ours back.
 * Then it tries again by itself; a new version or new settings from the phone start afresh.
 */
final class CrashGuard {
    private CrashGuard() {}

    private static final String PREFS = "crash_guard";
    private static final long WINDOW_MS = 3 * 60_000L, ASIDE_MS = 5 * 60_000L;
    static final long SETTLE_MS = 20_000L;
    private static volatile boolean recorded;

    /** Puts the crash recorder first in line (once per process). */
    static void install(Context c) {
        final Context app = c.getApplicationContext();
        // a new version gets a fresh try
        try {
            int v = app.getPackageManager().getPackageInfo(app.getPackageName(), 0).versionCode;
            if (prefs(app).getInt("version", 0) != v) {
                prefs(app).edit().remove("starts").remove("crashes").putInt("version", v).commit();
            }
        } catch (Throwable ignored) {}
        Thread.UncaughtExceptionHandler cur = Thread.getDefaultUncaughtExceptionHandler();
        if (cur instanceof Recorder) return;
        Thread.setDefaultUncaughtExceptionHandler(new Recorder(app, cur));
    }

    private static final class Recorder implements Thread.UncaughtExceptionHandler {
        private final Context app;
        private final Thread.UncaughtExceptionHandler before;
        Recorder(Context app, Thread.UncaughtExceptionHandler before) { this.app = app; this.before = before; }
        @Override public void uncaughtException(Thread t, Throwable e) {
            if (!recorded) {
                recorded = true;
                try { add(app, "crashes"); } catch (Throwable ignored) {}
            }
            if (before != null) before.uncaughtException(t, e);
        }
    }

    /** A fresh try: a new version, or settings sent from the phone. */
    static void reset(Context c) {
        try { prefs(c).edit().remove("starts").remove("crashes").commit(); } catch (Throwable ignored) {}
    }

    /** The home starts: written down until it settles or closes normally. */
    static void started(Context c) { try { add(c, "starts"); } catch (Throwable ignored) {} }

    /** The home lived [SETTLE_MS], or closed normally: its start was a good one. */
    static void settled(Context c) {
        try { prefs(c).edit().remove("starts").apply(); } catch (Throwable ignored) {}
    }

    /** True while the launcher crashed too often lately: the TV's own home should be on screen. */
    static boolean standingAside(Context c) {
        try {
            long now = System.currentTimeMillis();
            for (String key : new String[]{"crashes", "starts"}) {
                List<Long> recent = new ArrayList<>();
                for (long t : times(prefs(c).getString(key, ""))) if (t <= now && now - t < WINDOW_MS + ASIDE_MS) recent.add(t);
                List<Long> burst = new ArrayList<>();
                for (long t : recent) {
                    int n = 0;
                    for (long u : recent) if (Math.abs(u - t) < WINDOW_MS) n++;
                    if (n >= 2) burst.add(t);
                }
                long last = 0;
                for (long t : burst) last = Math.max(last, t);
                if (burst.size() >= 2 && now - last < ASIDE_MS) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

    /** Opens the TV's own home (never ours). False when there is none to hand over to. */
    static boolean openStockHome(Context c) {
        try {
            PackageManager pm = c.getPackageManager();
            ActivityInfo pick = null;
            for (ResolveInfo r : pm.queryIntentActivities(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)) {
                ActivityInfo a = r.activityInfo;
                if (a.packageName.equals(c.getPackageName()) || a.name.endsWith("FallbackHome")
                        || a.name.endsWith("ResolverActivity") || a.name.endsWith("RecoveryActivity")) continue;
                if (pick == null || a.packageName.contains("tvlauncher") || a.packageName.contains("launcherx")) pick = a;
            }
            if (pick == null) {
                HomeKeyService.log("guard: crashing, but no other home to hand over to");
                return false;
            }
            c.startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                    .setClassName(pick.packageName, pick.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            HomeKeyService.log("guard: crashed twice lately, the TV's own home (" + pick.packageName + ") for a few minutes");
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static SharedPreferences prefs(Context c) { return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE); }

    private static void add(Context c, String key) {
        long now = System.currentTimeMillis();
        StringBuilder sb = new StringBuilder();
        List<Long> kept = new ArrayList<>();
        // a stamp from the future was written before the clock jumped (boxes start days behind)
        for (long t : times(prefs(c).getString(key, ""))) if (t <= now && now - t < WINDOW_MS + ASIDE_MS) kept.add(t);
        kept.add(now);
        for (int i = Math.max(0, kept.size() - 6); i < kept.size(); i++) {
            if (sb.length() > 0) sb.append(',');
            sb.append(kept.get(i));
        }
        prefs(c).edit().putString(key, sb.toString()).commit();
    }

    private static List<Long> times(String s) {
        List<Long> out = new ArrayList<>();
        if (s == null) return out;
        for (String p : s.split(",")) {
            try { if (!p.isEmpty()) out.add(Long.parseLong(p)); } catch (NumberFormatException ignored) {}
        }
        return out;
    }
}
