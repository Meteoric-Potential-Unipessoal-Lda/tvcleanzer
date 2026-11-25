package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.res.Resources;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;

/**
 * Weather icons (1.30, the owner's «Weather Icons Pack»): 20 colour pictures in the APK
 * (res/drawable-nodpi/wx_NAME_SIZE.png, 64, 128 and 256 px), so they show with no internet.
 * Chosen by the WMO weather code (Open-Meteo, and met.no through Weather.wmo) and by day or
 * night at the city, worked out from the sun here: the weather request stays as it was.
 * Drawn as they are: no tint, their own colours and transparency.
 */
final class WeatherIcons {
    private WeatherIcons() {}

    /** The pack's weather-map.json: WMO code → picture, [day, night] where it has two. */
    static String forCode(int code, boolean day) {
        switch (code) {
            case 0: return day ? "clear_day" : "clear_night";
            case 1: case 2: return day ? "partly_cloudy_day" : "partly_cloudy_night";
            case 3: return "overcast";
            case 45: case 48: return "fog";
            case 51: case 53: case 55: return "drizzle";
            case 56: case 57: case 66: case 67: return "sleet";
            case 61: case 63: return "rain";
            case 65: case 82: return "heavy_rain";
            case 71: case 73: case 77: case 85: return "snow";
            case 75: case 86: return "heavy_snow";
            case 80: case 81: return day ? "showers_day" : "showers_night";
            case 95: return "thunderstorm";
            case 96: case 99: return "thunderstorm_rain";
            default: return "unknown";
        }
    }

    /** The picture for what [Weather.line] shows now; "unknown" when the TV has no weather to
     *  show (no answer yet, or no connection); null when there is no weather line at all. */
    static String name(Prefs p) {
        if (!p.hasWeather()) return null;
        if (p.weatherTs() == 0) return "unknown";
        long now = System.currentTimeMillis();
        return forCode(p.weatherCode(), isDay(p.weatherLat(), p.weatherLon(), now));
    }

    /** The icon for a line of text [textPx] high: the pack's nearest size at or above what is
     *  drawn (so it is only ever made smaller, never blurred up), bounds set, no tint. */
    static Drawable icon(Context c, Prefs p, float textPx) {
        String n = name(p);
        if (n == null) return null;
        return byName(c, n, Math.max(1, Math.round(textPx * 1.4f)));
    }

    /** The picture [n] («clear_day») [px] wide (1.42: the forecast's days too). */
    static Drawable byName(Context c, String n, int px) {
        int src = px <= 64 ? 64 : px <= 128 ? 128 : 256;
        Resources r = c.getResources();
        int id = r.getIdentifier("wx_" + n + "_" + src, "drawable", c.getPackageName());
        if (id == 0) id = r.getIdentifier("wx_unknown_" + src, "drawable", c.getPackageName());
        if (id == 0) return null;
        Drawable d;
        try {
            d = r.getDrawable(id, null).mutate();
        } catch (Exception e) {
            return null;
        }
        if (d instanceof BitmapDrawable) {
            ((BitmapDrawable) d).setFilterBitmap(true);
            ((BitmapDrawable) d).setAntiAlias(true);
        }
        d.setTintList(null);
        d.setBounds(0, 0, px, px);
        return d;
    }

    /** The picture at [px] across, for an ImageView (the top bar's weather block, 1.31). */
    static Drawable picture(Context c, Prefs p, int px) {
        return icon(c, p, px / 1.4f);
    }

    /** «📍 Наманган · ясно»: a drawn map pin (the text's colour) before [text]. */
    static CharSequence withPin(String text, android.widget.TextView v) {
        float s = v.getTextSize();
        Drawable pin = new Pin(v.getCurrentTextColor());
        pin.setBounds(0, 0, Math.round(s * 0.8f), Math.round(s * 1.0f));
        android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder("\uFFFC");
        sb.setSpan(new IconSpan(pin, Math.round(s * 0.4f)), 0, 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sb.append(text);
        return sb;
    }

    /** An outline map pin: a round head with a hole and a point below. */
    static final class Pin extends Drawable {
        private final android.graphics.Paint paint = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
        Pin(int color) {
            paint.setColor(color);
            paint.setStyle(android.graphics.Paint.Style.STROKE);
            paint.setStrokeJoin(android.graphics.Paint.Join.ROUND);
            paint.setStrokeCap(android.graphics.Paint.Cap.ROUND);
        }
        @Override public void draw(android.graphics.Canvas cv) {
            android.graphics.Rect b = getBounds();
            float w = b.width(), h = b.height(), sw = Math.max(1f, w * 0.13f);
            paint.setStrokeWidth(sw);
            float cx = b.left + w / 2f, r = w / 2f - sw, cy = b.top + sw / 2f + r;
            android.graphics.Path path = new android.graphics.Path();
            path.arcTo(new android.graphics.RectF(cx - r, cy - r, cx + r, cy + r), 140, 260, true);
            path.lineTo(cx, b.bottom - sw / 2f);
            path.close();
            cv.drawPath(path, paint);
            cv.drawCircle(cx, cy, r * 0.35f, paint);
        }
        @Override public void setAlpha(int a) { paint.setAlpha(a); }
        @Override public void setColorFilter(android.graphics.ColorFilter f) { paint.setColorFilter(f); }
        @Override public int getOpacity() { return android.graphics.PixelFormat.TRANSLUCENT; }
    }

    /** Puts the icon before the weather text already in [v]. Inside the text, not beside the
     *  view: on the clock home the line is as wide as the screen and centred, and an icon at the
     *  view's edge would stand far from the words. */
    static void apply(Context c, Prefs p, android.widget.TextView v) {
        CharSequence t = v.getText();
        if (t == null || t.length() == 0) return;
        Drawable d = icon(c, p, v.getTextSize());
        if (d == null) return;
        android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder("￼");
        sb.setSpan(new IconSpan(d, Math.round(v.getTextSize() * 0.35f)), 0, 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sb.append(t.toString());
        v.setText(sb);
    }

    /** The icon in the line, centred on the text's height (the line grows to fit it), drawn as
     *  it is: the text's colour and shadow do not touch it. */
    static final class IconSpan extends android.text.style.ReplacementSpan {
        private final Drawable d;
        private final int gap;

        IconSpan(Drawable d, int gap) { this.d = d; this.gap = gap; }

        @Override
        public int getSize(android.graphics.Paint paint, CharSequence text, int start, int end,
                           android.graphics.Paint.FontMetricsInt fm) {
            if (fm != null) {
                android.graphics.Paint.FontMetricsInt p = paint.getFontMetricsInt();
                int h = d.getBounds().height(), th = p.descent - p.ascent;
                int extra = Math.max(0, h - th);
                fm.ascent = p.ascent - extra / 2;
                fm.descent = p.descent + (extra - extra / 2);
                fm.top = Math.min(p.top, fm.ascent);
                fm.bottom = Math.max(p.bottom, fm.descent);
            }
            return d.getBounds().width() + gap;
        }

        @Override
        public void draw(android.graphics.Canvas canvas, CharSequence text, int start, int end, float x,
                         int top, int y, int bottom, android.graphics.Paint paint) {
            android.graphics.Paint.FontMetricsInt p = paint.getFontMetricsInt();
            float mid = y + (p.ascent + p.descent) / 2f;
            canvas.save();
            canvas.translate(x, mid - d.getBounds().height() / 2f);
            d.draw(canvas);
            canvas.restore();
        }
    }

    /** Is the sun up at the city (above −0.833°, as sunrise and sunset are counted)? A short
     *  solar position formula (about a minute off); a city at 0, 0 (none set) goes by the clock. */
    static boolean isDay(double lat, double lon, long ms) {
        if (lat == 0 && lon == 0) {
            int h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY);
            return h >= 7 && h < 19;
        }
        double d = ms / 86400000.0 - 10957.5;               // days since 2000-01-01 12:00 UTC
        double g = Math.toRadians(357.529 + 0.98560028 * d);  // mean anomaly
        double q = 280.459 + 0.98564736 * d;                  // mean longitude
        double l = Math.toRadians(q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g));
        double e = Math.toRadians(23.439 - 0.00000036 * d);   // the Earth's tilt
        double dec = Math.asin(Math.sin(e) * Math.sin(l));
        double ra = Math.atan2(Math.cos(e) * Math.sin(l), Math.cos(l));
        double gmst = (18.697374558 + 24.06570982441908 * d) % 24;
        double ha = Math.toRadians(gmst * 15 + lon) - ra;
        double la = Math.toRadians(lat);
        double sinAlt = Math.sin(la) * Math.sin(dec) + Math.cos(la) * Math.cos(dec) * Math.cos(ha);
        return sinAlt > Math.sin(Math.toRadians(-0.833));
    }
}
