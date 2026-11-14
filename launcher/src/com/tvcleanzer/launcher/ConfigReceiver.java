package com.tvcleanzer.launcher;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;

/** Settings pushed from the TVCleanzer phone app over ADB. */
public class ConfigReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!"com.tvcleanzer.launcher.APPLY".equals(intent.getAction())) return;
        Prefs p = new Prefs(context);
        String skin = intent.getStringExtra("skin");
        if (skin != null) p.setSkin(Skin.byId(skin));
        if (intent.hasExtra("clock24")) p.setClock24(intent.getBooleanExtra("clock24", true));
        if (intent.hasExtra("labels")) p.setLabelsAlways(intent.getBooleanExtra("labels", false));
        if (intent.getBooleanExtra("resetFavorites", false)) p.resetFavorites();
        if (intent.hasExtra("anim")) p.setAnim(intent.getIntExtra("anim", Prefs.ANIM_FULL));
        if (intent.hasExtra("ringAccent")) p.setRingAccent(intent.getBooleanExtra("ringAccent", false));
        if (intent.hasExtra("tiles")) p.setTileSize(intent.getIntExtra("tiles", Prefs.TILES_NORMAL));
        if (intent.hasExtra("wallDim")) p.setWallDim(intent.getIntExtra("wallDim", 40));
        if (intent.hasExtra("ambient")) p.setAmbient(intent.getBooleanExtra("ambient", true));

        String[] fav = intent.getStringArrayExtra("favorites");
        if (fav != null) p.setFavorites(clean(fav));
        String[] hid = intent.getStringArrayExtra("hidden");
        if (hid != null) p.setHidden(new HashSet<>(clean(hid)));

        if (intent.hasExtra("wallpaper")) {
            if ("none".equals(intent.getStringExtra("wallpaper"))) Wallpaper.delete(context);
            p.bumpWallpaper(); // the phone wrote a new file (or removed it)
        }

        String pin = intent.getStringExtra("pin");
        if (Pin.valid(pin)) p.setPin(pin);
        String[] kidsApps = intent.getStringArrayExtra("kidsApps");
        if (kidsApps != null) p.setKidsApps(new HashSet<>(clean(kidsApps)));
        if (intent.hasExtra("kids")) {
            boolean on = intent.getBooleanExtra("kids", false);
            if (!on || p.hasPin()) p.setKids(on); // never lock without a PIN to get out
        }
        // HomeActivity listens to SharedPreferences and redraws itself.
    }

    private static List<String> clean(String[] in) {
        List<String> out = new ArrayList<>();
        for (String s : in) {
            if (s != null && s.matches("[A-Za-z0-9_.]+") && !out.contains(s)) out.add(s);
        }
        return out;
    }
}
