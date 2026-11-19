package com.tvcleanzer.launcher;

import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.util.DisplayMetrics;

/**
 * Tile art from the app's OWN square icon (every app ships one; TV banners are 16:9 and got
 * cut in square tiles: an owner's photo showed «Google P…», «areHub T»). Nothing is downloaded
 * or bundled: the picture is what the app brought to the TV, as on any phone launcher.
 *  - adaptive icons (Android 8+): their own background fills the card, the picture centred;
 *  - older icons: drawn centred on a plate of their own main colour.
 */
final class IconArt {
    private IconArt() {}

    /** The app's icon in the best density it ships: launcher-size icons look soft on a TV. */
    static Drawable icon(PackageManager pm, AppEntry a) {
        try {
            ActivityInfo info = a.info;
            ApplicationInfo ai = info.applicationInfo;
            int res = info.getIconResource();
            if (res == 0) res = ai.icon;
            if (res != 0) {
                Resources r = pm.getResourcesForApplication(ai);
                Drawable d = r.getDrawableForDensity(res, DisplayMetrics.DENSITY_XXXHIGH, null);
                if (d != null) return d;
            }
        } catch (Throwable ignored) {}
        return a.loadIcon(pm);
    }

    /** A w×h card picture (the card's rounded corners clip it). Null if nothing could be drawn. */
    static Bitmap tile(Drawable icon, int w, int h) {
        if (icon == null || w <= 0 || h <= 0) return null;
        try {
            Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(out);
            if (Build.VERSION.SDK_INT >= 26 && icon instanceof android.graphics.drawable.AdaptiveIconDrawable) {
                android.graphics.drawable.AdaptiveIconDrawable ad = (android.graphics.drawable.AdaptiveIconDrawable) icon;
                Drawable bg = ad.getBackground(), fg = ad.getForeground();
                // the background layer covers the whole card (square layer, centre-cropped)
                int side = Math.max(w, h);
                if (bg != null) {
                    bg.setBounds((w - side) / 2, (h - side) / 2, (w + side) / 2, (h + side) / 2);
                    bg.draw(c);
                } else {
                    plate(c, w, h, fg == null ? 0xFF2B3446 : mainColor(fg));
                }
                if (fg != null) {
                    // the safe zone (66 of 108 units) ends up about 60 % of the card's height
                    int s = Math.round(h * 1.0f);
                    fg.setBounds((w - s) / 2, (h - s) / 2, (w + s) / 2, (h + s) / 2);
                    fg.draw(c);
                }
                return out;
            }
            int[] info = analyse(icon);
            plate(c, w, h, info[0]);
            int s = Math.round(h * (info[1] == 1 ? 0.62f : 0.68f));
            int l = (w - s) / 2, t = (h - s) / 2;
            if (info[1] == 1) {
                // a square icon with its own background: round its corners like an app icon
                Bitmap ib = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888);
                Canvas ic = new Canvas(ib);
                icon.setBounds(0, 0, s, s);
                icon.draw(ic);
                Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
                p.setShader(new android.graphics.BitmapShader(ib, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP));
                c.save();
                c.translate(l, t);
                float r = s * 0.22f;
                c.drawRoundRect(new RectF(0, 0, s, s), r, r, p);
                c.restore();
                ib.recycle();
            } else {
                icon.setBounds(l, t, l + s, t + s);
                icon.draw(c);
            }
            return out;
        } catch (Throwable e) {
            return null;
        }
    }

    /** A soft colour wash for the «Витрина» background: the picture squeezed to a few pixels
     *  and stretched back (bilinear), so only its colours stay. */
    static Bitmap wash(Drawable d) {
        if (d == null) return null;
        try {
            Bitmap tiny = Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(tiny);
            c.drawColor(0xFF0B1020);
            d.setBounds(0, 0, 16, 9);
            d.draw(c);
            Bitmap mid = Bitmap.createScaledBitmap(tiny, 64, 36, true);
            tiny.recycle();
            Bitmap big = Bitmap.createScaledBitmap(mid, 256, 144, true);
            mid.recycle();
            return big;
        } catch (Throwable e) {
            return null;
        }
    }

    /** Vertical gradient plate of [color]: a touch lighter on top, darker below. */
    private static void plate(Canvas c, int w, int h, int color) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setShader(new LinearGradient(0, 0, 0, h, mix(color, 0xFFFFFFFF, 0.14f), mix(color, 0xFF000000, 0.28f),
                Shader.TileMode.CLAMP));
        c.drawRect(0, 0, w, h, p);
    }

    /** {plate colour, 1 if the icon is a full square with its own background}. */
    private static int[] analyse(Drawable icon) {
        Bitmap b = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        icon.setBounds(0, 0, 24, 24);
        icon.draw(c);
        long r = 0, g = 0, bl = 0, n = 0;
        int opaque = 0;
        for (int y = 0; y < 24; y++) {
            for (int x = 0; x < 24; x++) {
                int px = b.getPixel(x, y);
                int a = px >>> 24;
                if (a > 200) {
                    opaque++;
                    r += (px >> 16) & 0xFF;
                    g += (px >> 8) & 0xFF;
                    bl += px & 0xFF;
                    n++;
                }
            }
        }
        b.recycle();
        boolean full = opaque > 24 * 24 * 0.86;
        if (n == 0) return new int[]{0xFF2B3446, 0};
        int avg = 0xFF000000 | ((int) (r / n) << 16) | ((int) (g / n) << 8) | (int) (bl / n);
        float lum = luminance(avg);
        int plate;
        if (!full && lum > 0.78f) plate = 0xFF2B3446;       // a white mark: dark plate, or it vanishes
        else if (!full && lum < 0.10f) plate = 0xFFE6EBF2;  // a black mark: light plate
        else plate = saturate(avg);
        return new int[]{plate, full ? 1 : 0};
    }

    private static int mainColor(Drawable d) {
        return analyse(d)[0];
    }

    private static float luminance(int c) {
        return (0.2126f * ((c >> 16) & 0xFF) + 0.7152f * ((c >> 8) & 0xFF) + 0.0722f * (c & 0xFF)) / 255f;
    }

    /** Averages come out greyish: push the colour back a little. */
    private static int saturate(int c) {
        float[] hsv = new float[3];
        android.graphics.Color.colorToHSV(c, hsv);
        hsv[1] = Math.min(1f, hsv[1] * 1.25f);
        return android.graphics.Color.HSVToColor(hsv);
    }

    private static int mix(int a, int b, float t) {
        int ar = (a >> 16) & 0xFF, ag = (a >> 8) & 0xFF, ab = a & 0xFF;
        int br = (b >> 16) & 0xFF, bg = (b >> 8) & 0xFF, bb = b & 0xFF;
        return 0xFF000000 | (Math.round(ar + (br - ar) * t) << 16) | (Math.round(ag + (bg - ag) * t) << 8)
                | Math.round(ab + (bb - ab) * t);
    }
}
