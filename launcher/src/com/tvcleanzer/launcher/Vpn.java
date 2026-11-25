package com.tvcleanzer.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.provider.Settings;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * The corner's VPN icon (0.78, a tester's idea): opens the VPN app itself, not the Wi-Fi
 * settings — the one that runs (always-on, else the one used last), or the only one there is;
 * several and none of them known to run: a list; none at all: the TV's VPN settings.
 * 1.41: the guess by «used last» opened the wrong app (TCL 50C655 with NetFix and another VPN
 * app): now the owner's pick comes first, and with several apps and no always-on one the list
 * is shown once and its pick kept (changed by a long OK on the icon or in the settings).
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

    static void open(Activity a) {
        PackageManager pm = a.getPackageManager();
        List<String> apps = apps(a);
        String saved = new Prefs(a).vpnApp();
        String pick = apps.contains(saved) ? saved : apps.size() == 1 ? apps.get(0) : alwaysOn(a, apps);
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
                    if (w == apps.size()) { settings(a); return; }
                    new Prefs(a).setVpnApp(apps.get(w));
                    android.widget.Toast.makeText(a, T.f("Запомнили {0}. Сменить — долгое ОК на значке VPN или в настройках лаунчера",
                            names[w]), android.widget.Toast.LENGTH_LONG).show();
                    start(a, launch(pm, apps.get(w)));
                })
                .show();
    }

    private static String alwaysOn(Context c, List<String> apps) {
        try {
            String on = Settings.Secure.getString(c.getContentResolver(), "always_on_vpn_app");
            if (on != null && apps.contains(on)) return on;
        } catch (Throwable ignored) {}
        return null;
    }

    private static String label(PackageManager pm, String p) {
        try { return pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString(); } catch (Throwable t) { return p; }
    }

    /** What the settings row shows: the chosen app, or «Спрашивать». */
    static String chosenName(Context c) {
        List<String> apps = apps(c);
        String saved = new Prefs(c).vpnApp();
        if (apps.contains(saved)) return label(c.getPackageManager(), saved);
        if (apps.size() == 1) return label(c.getPackageManager(), apps.get(0));
        return T.t("Спрашивать");
    }

    /** The owner picks the app the icon opens; [done] runs after (the settings redraw). */
    static void choose(Activity a, Runnable done) {
        PackageManager pm = a.getPackageManager();
        List<String> apps = apps(a);
        if (apps.isEmpty()) { settings(a); return; }
        String[] names = new String[apps.size() + 1];
        for (int i = 0; i < apps.size(); i++) names[i] = label(pm, apps.get(i));
        names[apps.size()] = T.t("Спрашивать");
        new AlertDialog.Builder(a, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("Значок VPN открывает"))
                .setItems(names, (d, w) -> {
                    new Prefs(a).setVpnApp(w == apps.size() ? "" : apps.get(w));
                    if (done != null) done.run();
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
