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
        HttpURLConnection c = null;
        try {
            URL u = new URL(String.format(Locale.US,
                    "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
                            + "&current=temperature_2m,weather_code&timezone=auto",
                    p.weatherLat(), p.weatherLon()));
            c = (HttpURLConnection) u.openConnection();
            c.setConnectTimeout(8000);
            c.setReadTimeout(8000);
            if (c.getResponseCode() != 200) return false;
            InputStream in = c.getInputStream();
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            JSONObject cur = new JSONObject(b.toString("UTF-8")).getJSONObject("current");
            p.setWeatherNow((int) Math.round(cur.getDouble("temperature_2m")), cur.getInt("weather_code"));
            return true;
        } catch (Exception e) {
            return false;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    /** "6° · облачно · Оренбург", or null when there is nothing (yet) to show. */
    static String line(Prefs p) {
        if (!p.hasWeather() || p.weatherTs() == 0) return null;
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
