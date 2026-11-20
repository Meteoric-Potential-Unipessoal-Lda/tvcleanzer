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
        if ("com.tvcleanzer.launcher.PASTE".equals(intent.getAction())) {
            // Russian (any) text from the phone: `input text` only types Latin letters. The phone
            // puts it on the TV's clipboard through us, then presses Paste (0.42+).
            String text = intent.getStringExtra("text");
            if (text == null) return;
            try {
                android.content.ClipboardManager cm =
                        (android.content.ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
                cm.setPrimaryClip(android.content.ClipData.newPlainText("TVCleanzer", text));
                setResultCode(1);
            } catch (Throwable ignored) {}
            return;
        }
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
        if (intent.hasExtra("inputs")) p.setInputsPos(intent.getIntExtra("inputs", Prefs.INPUTS_TOP));
        if (intent.hasExtra("favCols")) p.setFavCols(intent.getIntExtra("favCols", 0));
        if (intent.hasExtra("style")) p.setStyle(intent.getIntExtra("style", Prefs.STYLE_TILES));
        if (intent.hasExtra("icons")) p.setIcons(intent.getIntExtra("icons", Prefs.ICONS_AUTO));
        if (intent.hasExtra("skinAuto")) p.setSkinAuto(intent.getIntExtra("skinAuto", Prefs.SKIN_AUTO_OFF));
        if (intent.hasExtra("ambientSec")) p.setAmbientSec(intent.getIntExtra("ambientSec", 0));
        if (intent.hasExtra("clockPos")) p.setClockPos(intent.getIntExtra("clockPos", Prefs.CLOCK_CENTER));
        if (intent.hasExtra("clockSize")) p.setClockSize(intent.getIntExtra("clockSize", 100));
        if (intent.hasExtra("clockFont")) p.setClockFont(intent.getIntExtra("clockFont", 0));
        if (intent.hasExtra("weatherCity")) {
            String city = intent.getStringExtra("weatherCity");
            city = city == null ? "" : city.trim();
            if (city.length() > 40) city = city.substring(0, 40);
            float lat = intent.getFloatExtra("lat", 0f), lon = intent.getFloatExtra("lon", 0f);
            if (!city.equals(p.weatherCity()) || Math.abs(lat - p.weatherLat()) > 0.01f
                    || Math.abs(lon - p.weatherLon()) > 0.01f) {
                p.setWeatherPlace(city, lat, lon);
            }
        }
        if (intent.hasExtra("photos")) {
            String what = intent.getStringExtra("photos");
            if ("clear".equals(what)) Photos.clear(context); else Photos.trim(context);
            p.bumpPhotos();
        }
        if (intent.hasExtra("photoSec")) p.setPhotoSec(intent.getIntExtra("photoSec", 30));
        if (intent.hasExtra("homePhotos")) p.setHomePhotos(intent.getBooleanExtra("homePhotos", false));
        if (intent.hasExtra("splash")) p.setSplash(intent.getBooleanExtra("splash", true));
        if (intent.hasExtra("memPill")) p.setMemPill(intent.getBooleanExtra("memPill", true));
        if (intent.hasExtra("cleanBar")) p.setCleanBar(intent.getBooleanExtra("cleanBar", false));
        if (intent.hasExtra("heroTitle")) p.setHeroTitle(intent.getBooleanExtra("heroTitle", true));
        if (intent.hasExtra("appsBelow")) p.setAppsBelow(intent.getBooleanExtra("appsBelow", false));
        if (intent.hasExtra("favBottom")) p.setFavBottom(intent.getBooleanExtra("favBottom", false));
        if (intent.hasExtra("shelf")) p.setShelf(intent.getIntExtra("shelf", Prefs.SHELF_GLASS));
        if (intent.hasExtra("stockOff")) p.setStockOff(intent.getBooleanExtra("stockOff", false));
        if (intent.hasExtra("keyFilter")) {
            p.setKeyFilter(intent.getBooleanExtra("keyFilter", true));
            HomeKeyService s = HomeKeyService.running;
            if (s != null) s.updateKeyFilter();
        }
        if (intent.hasExtra("prevDream")) {
            String d = intent.getStringExtra("prevDream");
            if (d != null && (d.isEmpty() || d.matches("[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+"))) p.setPrevDream(d);
        }
        if (intent.hasExtra("autostart")) {
            String a = intent.getStringExtra("autostart");
            // a package, or a TV input: «input:<TvInputInfo id>» (HDMI…) / «input:tv:<pkg>» (live TV)
            p.setAutostart(a != null && (a.matches("[A-Za-z0-9_.]+") || a.matches("input:[A-Za-z0-9_.:/$-]+")) ? a : "");
        }

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
