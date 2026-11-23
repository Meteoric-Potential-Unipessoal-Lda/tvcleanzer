package com.tvcleanzer.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.usage.UsageStats;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.provider.Settings;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The corner's VPN icon (0.78, a tester's idea): opens the VPN app itself, not the Wi-Fi
 * settings — the one that runs (always-on, else the one used last), or the only one there is;
 * several and none of them known to run: a list; none at all: the TV's VPN settings.
 */
final class Vpn {
    private Vpn() {}

    /** Apps with a VPN service that can be opened (TV menu or phone menu). */
    static List<String> apps(Context c) {
        PackageManager pm = c.getPackageManager();
        Set<String> pk = new LinkedHashSet<>();
        try {
            for (ResolveInfo ri : pm.queryIntentServices(new Intent("android.net.VpnService"), 0)) {
                pk.add(ri.serviceInfo.packageName);
            }
        } catch (Throwable ignored) {}
        List<String> out = new ArrayList<>();
        for (String p : pk) if (launch(pm, p) != null) out.add(p);
        return out;
    }

    private static Intent launch(PackageManager pm, String p) {
        try {
            Intent i = pm.getLeanbackLaunchIntentForPackage(p);
            if (i == null) i = pm.getLaunchIntentForPackage(p);
            return i;
        } catch (Throwable t) {
            return null;
        }
    }

    /** The VPN app that most likely runs now: always-on if the TV says so, else used last. */
    private static String running(Context c, List<String> apps) {
        try {
            String on = Settings.Secure.getString(c.getContentResolver(), "always_on_vpn_app");
            if (on != null && apps.contains(on)) return on;
        } catch (Throwable ignored) {}
        if (!HomeKeyService.usageAccess(c)) return null;
        try {
            UsageStatsManager usm = (UsageStatsManager) c.getSystemService(Context.USAGE_STATS_SERVICE);
            long now = System.currentTimeMillis();
            Map<String, UsageStats> m = usm.queryAndAggregateUsageStats(now - 7L * 24 * 3600_000, now);
            String best = null;
            long at = 0;
            for (String p : apps) {
                UsageStats s = m.get(p);
                if (s != null && s.getLastTimeUsed() > at) { at = s.getLastTimeUsed(); best = p; }
            }
            return best;
        } catch (Throwable t) {
            return null;
        }
    }

    static void open(Activity a) {
        PackageManager pm = a.getPackageManager();
        List<String> apps = apps(a);
        String pick = apps.size() == 1 ? apps.get(0) : running(a, apps);
        if (pick != null) { start(a, launch(pm, pick)); return; }
        if (apps.isEmpty()) { settings(a); return; }
        String[] names = new String[apps.size() + 1];
        for (int i = 0; i < apps.size(); i++) {
            CharSequence l;
            try { l = pm.getApplicationLabel(pm.getApplicationInfo(apps.get(i), 0)); } catch (Throwable t) { l = apps.get(i); }
            names[i] = l.toString();
        }
        names[apps.size()] = T.t("Настройки VPN");
        new AlertDialog.Builder(a, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("VPN-приложения"))
                .setItems(names, (d, w) -> {
                    if (w == apps.size()) settings(a); else start(a, launch(pm, apps.get(w)));
                })
                .show();
    }

    private static void settings(Activity a) {
        for (String action : new String[]{"android.net.vpn.SETTINGS", Settings.ACTION_WIRELESS_SETTINGS, Settings.ACTION_SETTINGS}) {
            try {
                a.startActivity(new Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                return;
            } catch (Throwable ignored) {}
        }
    }

    private static void start(Activity a, Intent i) {
        if (i == null) { settings(a); return; }
        try { a.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); } catch (Throwable t) { settings(a); }
    }
}
