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
            err += " / " + name(e);
        }
        // Open-Meteo unreachable from some networks: the Norwegian Met Institute as a second source.
        try {
            fetchMetNo(p);
            return true;
        } catch (Exception e) {
            p.setWeatherError(err + " / met.no " + name(e));
            return false;
        }
    }

    private static String get(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(8000);
            c.setReadTimeout(8000);
            // api.met.no asks every client to name itself
            c.setRequestProperty("User-Agent", "TVCleanzerLauncher/0.24 (dayavacorp@gmail.com)");
            int code = c.getResponseCode();
            if (code != 200) throw new java.io.IOException("HTTP " + code);
            InputStream in = c.getInputStream();
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            return b.toString("UTF-8");
        } finally {
            c.disconnect();
        }
    }

    private static void fetchMetNo(Prefs p) throws Exception {
        String body = get(String.format(Locale.US,
                "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.3f&lon=%.3f",
                p.weatherLat(), p.weatherLon()));
        JSONObject first = new JSONObject(body).getJSONObject("properties")
                .getJSONArray("timeseries").getJSONObject(0).getJSONObject("data");
        double t = first.getJSONObject("instant").getJSONObject("details").getDouble("air_temperature");
        String sym = "";
        JSONObject next = first.optJSONObject("next_1_hours");
        if (next == null) next = first.optJSONObject("next_6_hours");
        if (next != null) sym = next.getJSONObject("summary").optString("symbol_code", "");
        p.setWeatherNow((int) Math.round(t), wmo(sym));
    }

    /** met.no symbol ("lightrainshowers_day") → the WMO code that [describe] knows. */
    static int wmo(String sym) {
        String s = sym.replaceAll("_(day|night|polartwilight)$", "");
        if (s.contains("thunder")) return 95;
        if (s.contains("snowshowers")) return 85;
        if (s.contains("rainshowers") || s.contains("sleetshowers")) return 80;
        if (s.contains("snow")) return 73;
        if (s.contains("sleet")) return 67;
        if (s.contains("drizzle")) return 53;
        if (s.contains("rain")) return 63;
        if (s.equals("fog")) return 45;
        if (s.equals("cloudy")) return 3;
        if (s.equals("partlycloudy")) return 2;
        if (s.equals("fair")) return 1;
        if (s.equals("clearsky")) return 0;
        return 3;
    }

    private static void fetch(String url, Prefs p) throws Exception {
        JSONObject cur = new JSONObject(get(url)).getJSONObject("current");
        p.setWeatherNow((int) Math.round(cur.getDouble("temperature_2m")), cur.getInt("weather_code"));
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
