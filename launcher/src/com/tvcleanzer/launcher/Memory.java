package com.tvcleanzer.launcher;

import android.app.ActivityManager;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.provider.Settings;

import java.util.List;
import java.util.Locale;

/**
 * RAM on the home screen and a «free it» button (owners asked for what the stock «Recent apps»
 * screen of some TVs has). A launcher can only ask Android to close apps that sit in the
 * background (KILL_BACKGROUND_PROCESSES, granted at install): what is on screen, playing, the
 * keyboard and the TV's own persistent services are never touched — the system keeps them.
 */
final class Memory {
    private Memory() {}

    /** {available, total} bytes. */
    static long[] read(Context c) {
        ActivityManager am = (ActivityManager) c.getSystemService(Context.ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
        am.getMemoryInfo(mi);
        return new long[]{mi.availMem, mi.totalMem};
    }

    /** «ОЗУ 1,2 / 1,5 ГБ»: used of total. */
    static String label(Context c) {
        long[] m = read(c);
        double gb = 1024.0 * 1024 * 1024;
        String used = String.format(Locale.getDefault(), "%.1f", (m[1] - m[0]) / gb);
        String total = String.format(Locale.getDefault(), "%.1f", m[1] / gb);
        return T.f("ОЗУ {0} / {1} ГБ", used, total);
    }

    /** Asks Android to close every app now in the background. Returns how many MB came free
     *  (call off the UI thread: it waits a moment for the system to settle). */
    static long free(Context c) {
        long before = read(c)[0];
        ActivityManager am = (ActivityManager) c.getSystemService(Context.ACTIVITY_SERVICE);
        PackageManager pm = c.getPackageManager();
        String ime = "";
        try {
            String s = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
            if (s != null && s.contains("/")) ime = s.substring(0, s.indexOf('/'));
        } catch (Throwable ignored) {}
        List<ApplicationInfo> all;
        try { all = pm.getInstalledApplications(0); } catch (Throwable e) { return 0; }
        for (ApplicationInfo ai : all) {
            String p = ai.packageName;
            if (p.equals(c.getPackageName()) || p.equals(ime) || p.equals("android")
                    || (ai.flags & ApplicationInfo.FLAG_PERSISTENT) != 0
                    || p.contains("inputmethod") || p.contains("tvinput") || p.contains("tv.input")
                    || p.contains("systemui") || p.contains("bluetooth")) continue;
            try { am.killBackgroundProcesses(p); } catch (Throwable ignored) {}
        }
        try { Thread.sleep(900); } catch (InterruptedException ignored) {}
        long after = read(c)[0];
        return Math.max(0, (after - before) / (1024 * 1024));
    }
}
