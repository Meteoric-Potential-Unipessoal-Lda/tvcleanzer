package com.tvcleanzer.launcher;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;

/**
 * Current weather for the clock home screen. Open-Meteo (free, no key, no account): the phone
 * app geocodes the city the owner typed and sends its coordinates; the TV asks for the current
 * temperature and weather code every 30 minutes. Nothing about the owner is sent anywhere.
 */
final class Weather {
    private Weather() {}

    static final long MAX_AGE_MS = 30 * 60 * 1000L;

    /** Network call: run off the UI thread. Returns true when fresh data was saved. */
    static boolean refreshIfStale(Prefs p) {
        if (!p.hasWeather()) return false;
        if (System.currentTimeMillis() - p.weatherTs() < MAX_AGE_MS) return false;
        String q = String.format(Locale.US,
                "api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
                        + "&current=temperature_2m,weather_code&timezone=auto",
                p.weatherLat(), p.weatherLon());
        String err;
        try {
            fetch("https://" + q, p);
            return true;
        } catch (Exception e) {
            err = name(e);
        }
        // Old TVs: no fresh root certificates or a broken clock, so HTTPS fails. The request
        // carries only the city coordinates, so plain HTTP is an acceptable fallback.
        try {
            fetch("http://" + q, p);
            return true;
        } catch (Exception e) {
            p.setWeatherError(err + " / " + name(e));
            return false;
        }
    }

    private static void fetch(String url, Prefs p) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(8000);
            c.setReadTimeout(8000);
            int code = c.getResponseCode();
            if (code != 200) throw new java.io.IOException("HTTP " + code);
            InputStream in = c.getInputStream();
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            JSONObject cur = new JSONObject(b.toString("UTF-8")).getJSONObject("current");
            p.setWeatherNow((int) Math.round(cur.getDouble("temperature_2m")), cur.getInt("weather_code"));
        } finally {
            c.disconnect();
        }
    }

    private static String name(Exception e) {
        String m = e.getMessage();
        String s = e.getClass().getSimpleName() + (m == null ? "" : ": " + m);
        return s.length() > 120 ? s.substring(0, 120) : s;
    }

    /** "6° · облачно · Оренбург", or null when there is nothing (yet) to show. */
    static String line(Prefs p) {
        if (!p.hasWeather()) return null;
        if (p.weatherTs() == 0) return p.weatherError().isEmpty() ? null : p.weatherCity() + " · погода недоступна";
        if (System.currentTimeMillis() - p.weatherTs() > 6 * 60 * 60 * 1000L) return null; // too old
        int t = p.weatherTemp();
        return (t > 0 ? "+" : "") + t + "° · " + describe(p.weatherCode()) + " · " + p.weatherCity();
    }

    /** WMO weather interpretation codes (Open-Meteo). */
    static String describe(int code) {
        if (code == 0) return "ясно";
        if (code <= 2) return "переменная облачность";
        if (code == 3) return "пасмурно";
        if (code == 45 || code == 48) return "туман";
        if (code >= 51 && code <= 57) return "морось";
        if (code >= 61 && code <= 67) return "дождь";
        if (code >= 71 && code <= 77) return "снег";
        if (code >= 80 && code <= 82) return "ливень";
        if (code == 85 || code == 86) return "снегопад";
        if (code >= 95) return "гроза";
        return "облачно";
    }
}
