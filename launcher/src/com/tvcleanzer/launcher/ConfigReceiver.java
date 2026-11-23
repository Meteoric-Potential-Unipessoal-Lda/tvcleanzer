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
        if (intent.hasExtra("mouse")) {
            // the virtual mouse: 1 through the Home-key service (gestures), 5 an ordinary overlay
            // whose touches the phone makes over ADB (0.79: a be311 box switches the service off
            // at once), 2 neither the service nor the overlay permission, 4 could not start
            HomeKeyService s = HomeKeyService.running;
            boolean on = intent.getBooleanExtra("mouse", false);
            if (!on) {
                if (s != null) s.mouse().stop();
                Mouse.plain(context).stop();
                setResultCode(1);
                return;
            }
            // 0.81: a service that has just (re)started may be one the firmware kills within a
            // second (be311: «the mouse works for a second»), so it carries the mouse only once it
            // has lived 8 s, or when there is no overlay permission to fall back on
            boolean settled = s != null
                    && android.os.SystemClock.elapsedRealtime() - HomeKeyService.connectedAt > 8000;
            if (s != null && android.os.Build.VERSION.SDK_INT >= 24 && (settled || !Mouse.canOverlay(context))) {
                Mouse.plain(context).stop();
                setResultCode(s.mouse().start() ? 1 : 4);
                return;
            }
            if (Mouse.canOverlay(context)) {
                if (s != null) s.mouse().stop();
                setResultCode(Mouse.plain(context).start() ? 5 : 4);
                return;
            }
            setResultCode(2);
            return;
        }
        if (intent.hasExtra("locale")) {
            // the TV's system language (0.59): the phone granted CHANGE_CONFIGURATION first
            String r = Locales.apply(intent.getStringExtra("locale"));
            setResultCode("ok".equals(r) ? 1 : 2);
            setResultData(r);
            return;
        }
        Prefs p = new Prefs(context);
        String skin = intent.getStringExtra("skin");
        if (skin != null) p.setSkin(Skin.byId(skin));
        if (intent.hasExtra("clock24")) p.setClock24(intent.getBooleanExtra("clock24", true));
        if (intent.hasExtra("labels")) p.setLabelsAlways(intent.getBooleanExtra("labels", false));
        if (intent.getBooleanExtra("resetFavorites", false)) p.resetFavorites();
        if (intent.hasExtra("anim")) p.setAnim(intent.getIntExtra("anim", Prefs.ANIM_FULL));
        if (intent.hasExtra("ringAccent")) p.setRingAccent(intent.getBooleanExtra("ringAccent", false));
        if (intent.hasExtra("ringOff")) p.setRingOff(intent.getBooleanExtra("ringOff", false));
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
        if (intent.hasExtra("music")) {
            if ("clear".equals(intent.getStringExtra("music"))) Music.clear(context); else Music.trim(context);
        }
        if (intent.hasExtra("frameMusic")) p.setFrameMusic(intent.getBooleanExtra("frameMusic", true));
        if (intent.hasExtra("photoSec")) p.setPhotoSec(intent.getIntExtra("photoSec", 30));
        if (intent.hasExtra("homePhotos")) p.setHomePhotos(intent.getBooleanExtra("homePhotos", false));
        if (intent.hasExtra("splash")) p.setSplash(intent.getBooleanExtra("splash", true));
        if (intent.hasExtra("memPill")) p.setMemPill(intent.getBooleanExtra("memPill", true));
        if (intent.hasExtra("btPill")) p.setBtPill(intent.getBooleanExtra("btPill", true));
        if (intent.hasExtra("cleanBar")) p.setCleanBar(intent.getBooleanExtra("cleanBar", false));
        if (intent.hasExtra("heroTitle")) p.setHeroTitle(intent.getBooleanExtra("heroTitle", true));
        if (intent.hasExtra("greeting")) p.setGreeting(intent.getBooleanExtra("greeting", true));
        if (intent.hasExtra("barClock")) p.setBarClock(intent.getIntExtra("barClock", 0));
        if (intent.hasExtra("oneLine")) p.setOneLine(intent.getBooleanExtra("oneLine", false));
        if (intent.hasExtra("iconShape")) p.setIconShape(intent.getIntExtra("iconShape", Prefs.SHAPE_ROUNDED));
        if (intent.hasExtra("barStyle")) p.setBarStyle(intent.getIntExtra("barStyle", Prefs.BAR_MINI));
        if (intent.hasExtra("favAlign")) p.setFavAlign(intent.getIntExtra("favAlign", Prefs.FAV_START));
        if (intent.hasExtra("clockGlass")) p.setClockGlass(intent.getBooleanExtra("clockGlass", false));
        if (intent.hasExtra("noLabels")) p.setNoLabels(intent.getBooleanExtra("noLabels", false));
        if (intent.hasExtra("appsBelow")) p.setAppsBelow(intent.getBooleanExtra("appsBelow", false));
        if (intent.hasExtra("favBottom")) p.setFavBottom(intent.getBooleanExtra("favBottom", false));
        if (intent.hasExtra("shelf")) p.setShelf(intent.getIntExtra("shelf", Prefs.SHELF_GLASS));
        if (intent.hasExtra("stockOff")) p.setStockOff(intent.getBooleanExtra("stockOff", false));
        if (intent.hasExtra("volSmooth")) {
            p.setVolSmooth(intent.getBooleanExtra("volSmooth", false));
            HomeKeyService s = HomeKeyService.running;
            if (s != null) s.updateKeyFilter();
        }
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
        if (intent.hasExtra("liveWall")) {
            if ("none".equals(intent.getStringExtra("liveWall"))) LiveWall.delete(context);
            p.bumpWallpaper(); // a new video (or none): the home screen picks it up
        }
        if (intent.hasExtra("liveWallOn")) p.setLiveWallOn(intent.getBooleanExtra("liveWallOn", true));

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
