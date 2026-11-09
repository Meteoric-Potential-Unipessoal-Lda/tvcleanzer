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

    private AppEntry(String pkg, String cls, String label, boolean leanback, ActivityInfo info) {
        this.pkg = pkg; this.cls = cls; this.label = label; this.leanback = leanback; this.info = info;
    }

    Intent launchIntent() {
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
            into.put(ai.packageName, new AppEntry(ai.packageName, ai.name,
                    l == null ? ai.packageName : l.toString(), leanback, ai));
        }
    }
}
