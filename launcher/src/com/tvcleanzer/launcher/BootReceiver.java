package com.tvcleanzer.launcher;

import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.provider.Settings;

/**
 * After a reboot, puts the Home-key service back if the TV dropped it (0.69).
 * TCL Smart TV Pro 55C745 (Android 11): Home and power-on worked until a reboot, then the
 * stock home stayed — the phone app turned the service back on only when it connected again.
 * Needs WRITE_SECURE_SETTINGS, granted by the phone app over ADB (pm grant); never touches a
 * service the owner switched off himself (Prefs.serviceWanted, cleared in onUnbind).
 */
public class BootReceiver extends BroadcastReceiver {
    static final String SERVICE = "com.tvcleanzer.launcher/com.tvcleanzer.launcher.HomeKeyService";
    private static final String KEY = "enabled_accessibility_services";

    @Override
    public void onReceive(Context c, Intent i) {
        final Context app = c.getApplicationContext();
        HomeKeyService.log("boot: service " + (HomeKeyService.running != null ? "running" : "not running")
                + ", listed " + listed(app) + ", wanted " + new Prefs(app).serviceWanted() + ", can write " + canWrite(app));
        KeeperJob.schedule(app);
        final PendingResult r = goAsync();
        // Android binds accessibility services around this moment: give it a few seconds
        new Thread(() -> {
            try {
                Thread.sleep(8000);
                keep(app);
            } catch (Throwable t) {
                HomeKeyService.log("boot: " + t);
            } finally {
                r.finish();
            }
        }).start();
    }

    static boolean canWrite(Context c) {
        return c.checkCallingOrSelfPermission("android.permission.WRITE_SECURE_SETTINGS") == PackageManager.PERMISSION_GRANTED;
    }

    static boolean listed(Context c) {
        String s = Settings.Secure.getString(c.getContentResolver(), KEY);
        if (s == null) return false;
        for (String p : s.split(":")) if (ours(p)) return true;
        return false;
    }

    static boolean ours(String p) {
        return p.equals(SERVICE) || p.equals("com.tvcleanzer.launcher/.HomeKeyService");
    }

    /** The service should run and does not: listed back (or off and on, when listed but not
     *  started — a TCL Google TV kept it «enabled» but never bound it). */
    static void keep(Context c) {
        if (HomeKeyService.running != null) { HomeKeyService.log("boot: service up"); return; }
        if (!new Prefs(c).serviceWanted()) { HomeKeyService.log("boot: the owner switched it off, left"); return; }
        if (!canWrite(c)) { HomeKeyService.log("boot: service down, no WRITE_SECURE_SETTINGS"); return; }
        final ContentResolver cr = c.getContentResolver();
        String cur = Settings.Secure.getString(cr, KEY);
        cur = cur == null || cur.equals("null") ? "" : cur;
        final String without = strip(cur);
        if (!without.equals(cur)) {
            HomeKeyService.log("boot: listed but not running, off and on");
            Settings.Secure.putString(cr, KEY, without);
            try { Thread.sleep(1500); } catch (InterruptedException ignored) {}
            on(cr, without);
        } else {
            HomeKeyService.log("boot: the TV dropped the service, put back");
            on(cr, without);
        }
    }

    private static void on(ContentResolver cr, String others) {
        try {
            Settings.Secure.putString(cr, KEY, others.isEmpty() ? SERVICE : others + ":" + SERVICE);
            Settings.Secure.putInt(cr, "accessibility_enabled", 1);
        } catch (Throwable t) {
            HomeKeyService.log("boot: " + t);
        }
    }

    /** The setting without our service (other services the TV has stay). */
    private static String strip(String s) {
        StringBuilder b = new StringBuilder();
        for (String p : s.split(":")) {
            // 1.06: the short spelling too («…launcher/.HomeKeyService», as the TV's own settings
            // write it) — left in, «off and on» never switched it off (a TCL: enabled, never bound)
            if (p.isEmpty() || ours(p)) continue;
            if (b.length() > 0) b.append(':');
            b.append(p);
        }
        return b.toString();
    }
}
