package com.tvcleanzer.launcher;

import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.util.DisplayMetrics;

/**
 * Tile art from the app's OWN square icon (every app ships one; TV banners are 16:9 and got
 * cut in square tiles: an owner's photo showed «Google P…», «areHub T»). Nothing is downloaded
 * or bundled: the picture is what the app brought to the TV, as on any phone launcher (other
 * brands' logos are theirs to ship, not ours to copy). See tile() for how each kind is drawn.
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
        return tile(icon, null, w, h);
    }

    /**
     * Drawn like a phone launcher's icon, edge to edge — not a small icon on a plate («обрубки»
     * owners complained about next to other launchers):
     *  - adaptive icons: both layers at launcher scale (the 72-of-108 viewport fills the card);
     *  - a square icon with its own background: fills the card, its baked corners pushed out;
     *  - a shape (round, logo with transparency): large on a plate of its own colour;
     *  - a tiny old icon (mdpi only, blurry when blown up) with a TV banner: the banner whole,
     *    on its own edge colour, so the brand reads instead of a smudge.
     */
    static Bitmap tile(Drawable icon, Drawable banner, int w, int h) {
        if (icon == null || w <= 0 || h <= 0) return null;
        try {
            Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(out);
            boolean square = Math.abs(w - h) < Math.max(w, h) * 0.2f;
            if (Build.VERSION.SDK_INT >= 26 && icon instanceof android.graphics.drawable.AdaptiveIconDrawable) {
                android.graphics.drawable.AdaptiveIconDrawable ad = (android.graphics.drawable.AdaptiveIconDrawable) icon;
                Drawable bg = ad.getBackground(), fg = ad.getForeground();
                // a launcher shows the middle 72 of the layers' 108 units
                int layer = Math.round(Math.max(w, h) * 1.5f);
                if (bg != null) {
                    // some background layers are see-through (Play Store on TVs came out grey on
                    // the dark card): an opaque underlay of the layer's own colour first
                    c.drawColor(opaqueCenter(bg));
                    bg.setBounds((w - layer) / 2, (h - layer) / 2, (w + layer) / 2, (h + layer) / 2);
                    bg.draw(c);
                } else {
                    plate(c, w, h, fg == null ? 0xFF2B3446 : mainColor(fg));
                }
                if (fg != null) {
                    // wide cards: the picture by the height, so it is not cut top and bottom
                    int s = square ? layer : Math.round(h * 1.35f);
                    fg.setBounds((w - s) / 2, (h - s) / 2, (w + s) / 2, (h + s) / 2);
                    fg.draw(c);
                }
                return out;
            }
            int[] info = analyse(icon);
            int natural = Math.max(icon.getIntrinsicWidth(), icon.getIntrinsicHeight());
            boolean tiny = natural > 0 && natural < Math.min(w, h) * 0.55f;
            if (tiny && banner != null && banner.getIntrinsicWidth() > 0 && banner.getIntrinsicHeight() > 0) {
                int[] bi = analyse(banner);
                plate(c, w, h, edgeColor(banner, bi[0]));
                float k = Math.min(w * 0.92f / banner.getIntrinsicWidth(), h * 0.92f / banner.getIntrinsicHeight());
                int bw = Math.round(banner.getIntrinsicWidth() * k), bh = Math.round(banner.getIntrinsicHeight() * k);
                banner.setBounds((w - bw) / 2, (h - bh) / 2, (w + bw) / 2, (h + bh) / 2);
                banner.draw(c);
                return out;
            }
            if (info[1] == 1) {
                // its own background: a little larger so baked-in corners fall outside. On a wide
                // card it goes by the height — by the width the picture was cut top and bottom
                // (rocket, diamonds, «CANALI TV» on an owner's photos) — and the sides take the
                // icon's own background colour, so it reads as one picture.
                int side = Math.round((square ? Math.max(w, h) : h) * 1.08f);
                Bitmap ib = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888);
                Canvas ic = new Canvas(ib);
                icon.setBounds(0, 0, side, side);
                icon.draw(ic);
                Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
                if (square) {
                    plate(c, w, h, info[0]);
                    c.drawBitmap(ib, (w - side) / 2f, (h - side) / 2f, p);
                } else {
                    // the sides take the colour from inside the icon and its left and right edges
                    // fade into it — a frame or corners of another tint showed as a seam (Calman)
                    c.drawColor(sideColor(ib, info[0]));
                    float left = (w - side) / 2f;
                    int save = c.saveLayer(left, 0, left + side, h, null);
                    c.drawBitmap(ib, left, (h - side) / 2f, p);
                    Paint m = new Paint();
                    m.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
                    m.setShader(new LinearGradient(left, 0, left + side, 0,
                            new int[]{0x00000000, 0xFF000000, 0xFF000000, 0x00000000},
                            new float[]{0f, 0.16f, 0.84f, 1f}, Shader.TileMode.CLAMP));
                    c.drawRect(left, 0, left + side, h, m);
                    c.restoreToCount(save);
                }
                ib.recycle();
                return out;
            }
            plate(c, w, h, info[0]);
            int s = Math.round(Math.min(w, h) * 0.78f);
            icon.setBounds((w - s) / 2, (h - s) / 2, (w + s) / 2, (h + s) / 2);
            icon.draw(c);
            return out;
        } catch (Throwable e) {
            return null;
        }
    }

    /**
     * A TV banner on a card of another shape: cropped at most a little (a whole crop cut
     * «calman» to «calmar» on an owner's photo), the rest of the card in the banner's own
     * edge colour. Null if the banner has no size.
     */
    static Bitmap banner(Drawable b, int w, int h) {
        if (b == null || w <= 0 || h <= 0) return null;
        int bw0 = b.getIntrinsicWidth(), bh0 = b.getIntrinsicHeight();
        if (bw0 <= 0 || bh0 <= 0) return null;
        try {
            float cover = Math.max(w / (float) bw0, h / (float) bh0);
            float contain = Math.min(w / (float) bw0, h / (float) bh0);
            float k = Math.min(cover, contain * 1.03f);
            Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(out);
            int bw = Math.round(bw0 * k), bh = Math.round(bh0 * k);
            if (bw < w || bh < h) c.drawColor(edgeColor(b, 0xFF1E2430));
            b.setBounds((w - bw) / 2, (h - bh) / 2, (w + bw) / 2, (h + bh) / 2);
            b.draw(c);
            return out;
        } catch (Throwable e) {
            return null;
        }
    }

    /** A layer's colour at its centre, made opaque. */
    private static int opaqueCenter(Drawable d) {
        try {
            Bitmap b = Bitmap.createBitmap(9, 9, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(b);
            d.setBounds(0, 0, 9, 9);
            d.draw(c);
            int px = b.getPixel(4, 4);
            b.recycle();
            if ((px >>> 24) == 0) return 0xFFFFFFFF;
            return 0xFF000000 | (px & 0xFFFFFF);
        } catch (Throwable t) {
            return 0xFFFFFFFF;
        }
    }

    /** The background along a full icon's left and right sides (inside its baked corners). */
    private static int sideColor(Bitmap b, int fallback) {
        int sz = b.getWidth();
        long r = 0, g = 0, bl = 0;
        int n = 0;
        int[] xs = {Math.round(sz * 0.2f), Math.round(sz * 0.8f) - 1};
        for (int x : xs) {
            for (int y = Math.round(sz * 0.3f); y < Math.round(sz * 0.7f); y += Math.max(1, sz / 40)) {
                int px = b.getPixel(x, y);
                if ((px >>> 24) < 200) continue;
                r += (px >> 16) & 0xFF;
                g += (px >> 8) & 0xFF;
                bl += px & 0xFF;
                n++;
            }
        }
        if (n < 6) return fallback;
        return 0xFF000000 | ((int) (r / n) << 16) | ((int) (g / n) << 8) | (int) (bl / n);
    }

    /** The colour along a banner's left edge (its own background), else [fallback]. */
    private static int edgeColor(Drawable d, int fallback) {
        try {
            Bitmap b = Bitmap.createBitmap(32, 18, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(b);
            d.setBounds(0, 0, 32, 18);
            d.draw(c);
            long r = 0, g = 0, bl = 0;
            int n = 0;
            for (int y = 2; y < 16; y++) {
                int px = b.getPixel(1, y);
                if ((px >>> 24) < 200) continue;
                r += (px >> 16) & 0xFF;
                g += (px >> 8) & 0xFF;
                bl += px & 0xFF;
                n++;
            }
            b.recycle();
            if (n < 6) return fallback;
            return 0xFF000000 | ((int) (r / n) << 16) | ((int) (g / n) << 8) | (int) (bl / n);
        } catch (Throwable t) {
            return fallback;
        }
    }

    /** A soft colour wash for the «Витрина» background: the picture squeezed to 8×5 pixels and
     *  stretched back in steps (bilinear), so only its colours stay — no letters or tile shapes.
     *  Never bright: a white icon (video, store apps) made the whole screen white and the clock
     *  unreadable (an owner's video), so every pixel is held below ~40 % brightness. */
    static Bitmap wash(Drawable d) {
        if (d == null) return null;
        try {
            Bitmap tiny = Bitmap.createBitmap(8, 5, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(tiny);
            c.drawColor(0xFF0B1020);
            d.setBounds(0, 0, 8, 5);
            d.draw(c);
            int[] px = new int[40];
            tiny.getPixels(px, 0, 8, 0, 0, 8, 5);
            float[] hsv = new float[3];
            for (int i = 0; i < px.length; i++) {
                android.graphics.Color.colorToHSV(px[i], hsv);
                hsv[1] = Math.min(1f, hsv[1] * 1.15f);
                // dark and greyish stays dark; bright colours are dimmed, white turns slate
                hsv[2] = Math.min(hsv[2], hsv[1] < 0.15f ? 0.22f : 0.42f);
                px[i] = android.graphics.Color.HSVToColor(hsv);
            }
            tiny.setPixels(px, 0, 8, 0, 0, 8, 5);
            Bitmap b = tiny;
            int[][] steps = {{24, 15}, {72, 45}, {256, 160}};
            for (int[] st : steps) {
                Bitmap n = Bitmap.createScaledBitmap(b, st[0], st[1], true);
                b.recycle();
                b = n;
            }
            return b;
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
