package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;

import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** One launchable app. Key = package name (stable across updates). */
final class AppEntry {
    final String pkg, cls, label;
    final boolean leanback;
    final ActivityInfo info;
    /** A firmware app without a menu icon, started by its exact screen (see FIRMWARE_APPS). */
    boolean plain;

    private AppEntry(String pkg, String cls, String label, boolean leanback, ActivityInfo info) {
        this.pkg = pkg; this.cls = cls; this.label = label; this.leanback = leanback; this.info = info;
    }

    /**
     * Apps of TV shells that have no icon of their own in the app list: their shell opens them
     * itself. Found on Yandex TV (Tuvio TD32FFBCV1, YaOS): YouTube (Cobalt), the Yandex app
     * store and the browser answer a plain MAIN intent, so they can sit in our launcher too.
     */
    private static final String[][] FIRMWARE_APPS = {
            {"com.yandex.tv.ytplayer", "dev.cobalt.app.MainActivity", "YouTube"},
            {"com.yandex.devices.appstore", "com.yandex.devices.feature.appstore.ui.presentation.main.MainActivity", "Магазин приложений"},
            {"com.yandex.browser.tv", "com.yandex.browser.tv.tvactivity.TvActivity", "Яндекс Браузер"},
    };

    Intent launchIntent() {
        if (plain) {
            return new Intent(Intent.ACTION_MAIN).setClassName(pkg, cls)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        }
        return new Intent(Intent.ACTION_MAIN)
                .addCategory(leanback ? Intent.CATEGORY_LEANBACK_LAUNCHER : Intent.CATEGORY_LAUNCHER)
                .setClassName(pkg, cls)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
    }

    /** TV banner (16:9) if the app has one, otherwise null. */
    Drawable loadBanner(PackageManager pm) {
        try {
            Drawable d = info.loadBanner(pm);
            if (d == null) d = info.applicationInfo.loadBanner(pm);
            return d;
        } catch (Throwable t) {
            return null;
        }
    }

    Drawable loadIcon(PackageManager pm) {
        try {
            return info.loadIcon(pm);
        } catch (Throwable t) {
            return null;
        }
    }

    /** TV apps first (LEANBACK_LAUNCHER), then phone-style apps; one entry per package. */
    static List<AppEntry> loadAll(Context c) {
        PackageManager pm = c.getPackageManager();
        Map<String, AppEntry> byPkg = new LinkedHashMap<>();
        collect(pm, byPkg, Intent.CATEGORY_LEANBACK_LAUNCHER, true);
        collect(pm, byPkg, Intent.CATEGORY_LAUNCHER, false);
        for (String[] f : FIRMWARE_APPS) {
            if (byPkg.containsKey(f[0])) continue;
            try {
                ResolveInfo ri = pm.resolveActivity(new Intent(Intent.ACTION_MAIN).setClassName(f[0], f[1]), 0);
                if (ri == null || ri.activityInfo == null || !ri.activityInfo.exported || !ri.activityInfo.enabled) continue;
                CharSequence l = ri.loadLabel(pm);
                String label = l == null || l.toString().trim().isEmpty() || l.toString().equals(f[0]) ? f[2] : l.toString();
                AppEntry e = new AppEntry(f[0], f[1], label, false, ri.activityInfo);
                e.plain = true;
                byPkg.put(f[0], e);
            } catch (Throwable ignored) {}
        }
        byPkg.remove(c.getPackageName());
        List<AppEntry> out = new ArrayList<>(byPkg.values());
        final Collator col = Collator.getInstance(Locale.getDefault());
        Collections.sort(out, (a, b) -> col.compare(a.label, b.label));
        return out;
    }

    private static void collect(PackageManager pm, Map<String, AppEntry> into,
                                String category, boolean leanback) {
        Intent i = new Intent(Intent.ACTION_MAIN).addCategory(category);
        List<ResolveInfo> list;
        try {
            list = pm.queryIntentActivities(i, 0);
        } catch (Throwable t) {
            return;
        }
        for (ResolveInfo ri : list) {
            ActivityInfo ai = ri.activityInfo;
            if (ai == null || into.containsKey(ai.packageName)) continue;
            CharSequence l = ri.loadLabel(pm);
            String label = l == null ? ai.packageName : l.toString();
            if (!leanback && serviceApp(ai, label)) continue;
            into.put(ai.packageName, new AppEntry(ai.packageName, ai.name, label, leanback, ai));
        }
    }

    /** Firmware service screens with a phone-style icon (MStar «com.mstar.…», «Disclaimer
     *  Customization», «Updater» on a Xiaomi): the stock home never showed them, they do not
     *  open anything useful, and owners thought the clean-up had added them. System apps only. */
    private static final java.util.regex.Pattern SERVICE = java.util.regex.Pattern.compile(
            "(^com\\.mstar\\.)|disclaimer|updater|upgrade|(^|\\.)ota(\\.|$)|factory|autotest|aging",
            java.util.regex.Pattern.CASE_INSENSITIVE);

    private static boolean serviceApp(ActivityInfo ai, String label) {
        if (ai.applicationInfo == null || (ai.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_SYSTEM) == 0) return false;
        String pkg = ai.packageName;
        boolean pkgLabel = label.equals(pkg) || label.matches("^[a-z][\\w]*(\\.[\\w]+){2,}.*");
        return pkgLabel || SERVICE.matcher(pkg).find() || SERVICE.matcher(label).find();
    }
}
