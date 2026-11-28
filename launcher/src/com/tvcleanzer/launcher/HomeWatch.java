package com.tvcleanzer.launcher;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 1.39: the way back to our home on a box that switches every accessibility service off a
 * second after it starts (be311 / t950s with com.master.t972, a system app: its Home button
 * opens its own screen by name, so being the HOME app is not enough). Without the Home-key
 * service, this watches which screen comes to the front (Android's usage events, the access the
 * phone grants over ADB) and, when the box's own home comes up, opens ours over it — allowed
 * from the background with «draw over other apps», which the phone grants too.
 *
 * It only acts while the Home-key service is not running (it waits while it is). A box
 * that fights back (its home again and again) gets a minute's pause, so the two never flicker.
 */
public class HomeWatch extends Service {
    private static final long TICK_MS = 700;
    private final Handler h = new Handler(Looper.getMainLooper());
    private final Set<String> homeClasses = new HashSet<>();
    private final Set<String> homePkgs = new HashSet<>();
    private final Set<String> skipped = new HashSet<>();
    private long since;
    private long pausedUntil;
    private final long[] recent = new long[4];
    private int ri;
    static volatile boolean on;

    /** Starts the watch where it is needed and can work; safe to call often. */
    static void ensure(Context c) {
        try {
            if (HomeKeyService.running != null) return;
            if (android.os.Build.VERSION.SDK_INT < 26) return; // no such boxes seen; keeps it simple
            if (on) return;
            // 1.77: say why the watch stays off (Yandex TV, Yandex services 3.375.6: the Home-key
            // service thrown out in seconds, and no «watch:» line at all in the report)
            String why = !Mouse.canOverlay(c) ? "no overlay permission"
                    : !usageAllowed(c) ? "no usage access"
                    : !isHomeApp(c) ? "not the HOME app"
                    : stockHomes(c, null, null).isEmpty() ? "no other home" : null;
            if (why != null) {
                if (!why.equals(lastWhy)) HomeKeyService.log("watch: off, " + why);
                lastWhy = why;
                return;
            }
            lastWhy = null;
            c.startForegroundService(new Intent(c, HomeWatch.class));
        } catch (Throwable t) {
            HomeKeyService.log("watch: " + t);
        }
    }

    private static String lastWhy;

    static boolean usageAllowed(Context c) {
        try {
            android.app.AppOpsManager ops = (android.app.AppOpsManager) c.getSystemService(Context.APP_OPS_SERVICE);
            int mode = ops.checkOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                    android.os.Process.myUid(), c.getPackageName());
            return mode == android.app.AppOpsManager.MODE_ALLOWED;
        } catch (Throwable t) {
            return false;
        }
    }

    static boolean isHomeApp(Context c) {
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        ResolveInfo ri = c.getPackageManager().resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY);
        String pkg = ri != null && ri.activityInfo != null ? ri.activityInfo.packageName : null;
        if (c.getPackageName().equals(pkg)) return true;
        // 1.77: Yandex / Sber homes only — the HOME role counts too. Yandex TV (services 3.375.6):
        // the role was ours («cmd shortcut get-default-launcher») while the lookup gave Yandex's
        // home. Not on Google TV: there launcherx also shows HDMI, the watch must stay out.
        if (pkg != null && HomeKeyService.FEATURE_HOMES.contains(pkg) && android.os.Build.VERSION.SDK_INT >= 29) {
            try {
                android.app.role.RoleManager rm = c.getSystemService(android.app.role.RoleManager.class);
                return rm != null && rm.isRoleHeld(android.app.role.RoleManager.ROLE_HOME);
            } catch (Throwable ignored) {}
        }
        return false;
    }

    /** The other home screens on the TV (packages), filling [classes] with their activities. */
    static Set<String> stockHomes(Context c, Set<String> pkgs, Set<String> classes) {
        Set<String> out = pkgs != null ? pkgs : new HashSet<>();
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        try {
            List<ResolveInfo> list = c.getPackageManager().queryIntentActivities(home, PackageManager.MATCH_DEFAULT_ONLY);
            for (ResolveInfo r : list) {
                String p = r.activityInfo.packageName;
                if (p.equals(c.getPackageName()) || p.equals("android") || p.equals("com.android.settings")
                        || p.equals("com.android.tv.settings")) continue;
                out.add(p);
                if (classes != null) {
                    classes.add(r.activityInfo.name);
                    if (r.activityInfo.targetActivity != null) classes.add(r.activityInfo.targetActivity);
                }
            }
        } catch (Throwable ignored) {}
        return out;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        on = true;
        try {
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            nm.createNotificationChannel(new NotificationChannel("watch", "Home", NotificationManager.IMPORTANCE_MIN));
            Notification n = new Notification.Builder(this, "watch")
                    .setSmallIcon(getApplicationInfo().icon)
                    .setContentTitle("TVCleanzer")
                    .setOngoing(true)
                    .build();
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                startForeground(7102, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(7102, n);
            }
        } catch (Throwable t) {
            HomeKeyService.log("watch: no foreground: " + t);
        }
        stockHomes(this, homePkgs, homeClasses);
        since = System.currentTimeMillis() - 2000;
        HomeKeyService.log("watch: on, homes " + homeClasses);
        h.post(tick);
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            // the Home-key service up (on that box only for a second or two): it does the job, the
            // watch waits and stays, so it is there again when the box switches the service off
            if (HomeKeyService.running != null) {
                h.postDelayed(this, TICK_MS * 3);
                return;
            }
            try {
                check();
            } catch (Throwable t) {
                HomeKeyService.log("watch: " + t);
            }
            h.postDelayed(this, TICK_MS);
        }
    };

    private void check() {
        if (CrashGuard.standingAside(this)) return; // 1.43: the TV's own home for a few minutes
        UsageStatsManager usm = (UsageStatsManager) getSystemService(Context.USAGE_STATS_SERVICE);
        long now = System.currentTimeMillis();
        UsageEvents ev = usm.queryEvents(since, now);
        UsageEvents.Event e = new UsageEvents.Event();
        String lastPkg = null, lastCls = null;
        long lastTs = since;
        while (ev.hasNextEvent()) {
            ev.getNextEvent(e);
            if (e.getEventType() == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                lastPkg = e.getPackageName();
                lastCls = e.getClassName();
                lastTs = e.getTimeStamp();
            }
        }
        if (lastPkg == null) return;
        since = lastTs + 1;
        frontPkg = lastPkg;
        if (!homePkgs.contains(lastPkg)) return;
        if (lastCls != null && !homeClasses.isEmpty() && !homeClasses.contains(lastCls)) {
            // its settings, search etc.: left alone; named once, to learn the home's other screens
            if (skipped.add(lastCls)) HomeKeyService.log("watch: " + lastPkg + "/" + lastCls + " is not its home screen, left");
            return;
        }
        long t = SystemClock.elapsedRealtime();
        if (t < pausedUntil) return;
        recent[ri++ % recent.length] = t;
        long oldest = Long.MAX_VALUE;
        for (long r : recent) oldest = Math.min(oldest, r);
        if (oldest > 0 && t - oldest < 20_000) {
            pausedUntil = t + 60_000;
            HomeKeyService.log("watch: " + lastPkg + " keeps coming back, pausing a minute");
            return;
        }
        HomeKeyService.log("watch: " + lastPkg + " came up, opening ours");
        openOurs();
        // 1.78: after the remote's Home key Android holds back starts from the background for a
        // few seconds (app-switch protection) and ours was lost — Yandex TV: power-on and the
        // voice «Домой» came back to us, the Home key never did («opening ours», Yandex stayed).
        // Looked at again a little later and once the hold is over.
        openedAt = SystemClock.elapsedRealtime();
        h.removeCallbacks(again);
        h.postDelayed(again, 2500);
        h.postDelayed(again, 5600);
    }

    private String frontPkg;
    private long openedAt;

    private final Runnable again = new Runnable() {
        @Override public void run() {
            try {
                if (SystemClock.elapsedRealtime() - openedAt > 8000) return;
                check(); // fresh events first (and the usual reaction if the home came up anew)
                if (frontPkg == null || !homePkgs.contains(frontPkg)) return; // ours or another app is in front
                if (SystemClock.elapsedRealtime() < pausedUntil) return;
                HomeKeyService.log("watch: " + frontPkg + " still in front, opening ours again");
                openOurs();
            } catch (Throwable t) {
                HomeKeyService.log("watch: " + t);
            }
        }
    };

    private void openOurs() {
        try {
            startActivity(new Intent(this, HomeActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        } catch (Throwable x) {
            HomeKeyService.log("watch: " + x);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        on = false;
        h.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
