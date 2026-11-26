package com.tvcleanzer.launcher;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.view.View;

/**
 * 1.54 «Стекло: матовое» (Sergey: «заблюрить стекло, будет красивее»): the glass shows the photo
 * behind it blurred. Android before 12 can't blur what lies under a view, so the photo itself is
 * blurred once (small, on the CPU) and each glass draws its own piece of it, found from where the
 * view sits on the screen. Photo wallpapers only; a video or a theme keeps the plain glass.
 */
final class Frost extends Drawable {
    static final int SCALE = 6;

    /** 1.67: «Матовое» over a video wallpaper (Sergey: «на видео фоне матовые блоки нужно
     *  сделать»): LiveWall puts a small blurred copy of the current frame here every ~0.6 s. */
    private static Bitmap liveBlur;
    private static final java.util.Set<Frost> onVideo =
            java.util.Collections.newSetFromMap(new java.util.WeakHashMap<Frost, Boolean>());

    /** A glass over the video wants frames (LiveWall makes none otherwise). */
    static boolean liveWanted() { return !onVideo.isEmpty(); }

    /** UI thread: a new blurred frame for every glass over the video. */
    static void liveFrame(Bitmap b) {
        liveBlur = b;
        for (Frost f : new java.util.ArrayList<>(onVideo)) f.invalidateSelf();
    }

    /** The video went away (stopped, another wallpaper): the glasses forget it. */
    static void liveGone() {
        liveBlur = null;
        onVideo.clear();
    }

    /** A glass over the video wallpaper: its picture comes from [liveFrame]. */
    static Frost overVideo(View host, float radius, int dim, Drawable over) {
        Frost f = new Frost(host, null, radius, dim, over);
        onVideo.add(f);
        return f;
    }

    /** [b] (a frame at screen/SCALE) blurred in place, as light as the photo's. */
    static void blurInPlace(Bitmap b) {
        int w = b.getWidth(), h = b.getHeight();
        int[] px = new int[w * h];
        b.getPixels(px, 0, w, 0, 0, w, h);
        for (int i = 0; i < 2; i++) box(px, w, h, 1);
        b.setPixels(px, 0, w, 0, 0, w, h);
    }
    private static Bitmap cacheSrc, cacheOut;
    private static int cacheW, cacheH;

    /** The photo as the screen shows it (centre crop), small and blurred; cached per photo. */
    static synchronized Bitmap blurred(Bitmap wall, int screenW, int screenH) {
        if (wall == null || screenW <= 0 || screenH <= 0) return null;
        if (wall == cacheSrc && screenW == cacheW && screenH == cacheH && cacheOut != null) return cacheOut;
        try {
            int w = Math.max(1, screenW / SCALE), h = Math.max(1, screenH / SCALE);
            Bitmap small = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(small);
            float s = Math.max((float) w / wall.getWidth(), (float) h / wall.getHeight());
            Matrix m = new Matrix();
            m.setScale(s, s);
            m.postTranslate((w - wall.getWidth() * s) / 2f, (h - wall.getHeight() * s) / 2f);
            c.drawBitmap(wall, m, new Paint(Paint.FILTER_BITMAP_FLAG));
            int[] px = new int[w * h];
            small.getPixels(px, 0, w, 0, 0, w, h);
            // 1.56: a light blur — the photo still shows through (testers: «прозрачности почти нет»)
            for (int i = 0; i < 2; i++) box(px, w, h, 1); // 1.57: lighter still
            small.setPixels(px, 0, w, 0, 0, w, h);
            cacheSrc = wall;
            cacheW = screenW;
            cacheH = screenH;
            cacheOut = small;
            return small;
        } catch (Throwable t) {
            return null;
        }
    }

    /** One box blur pass, rows then columns. */
    private static void box(int[] px, int w, int h, int r) {
        int[] tmp = new int[px.length];
        pass(px, tmp, w, h, r, true);
        pass(tmp, px, w, h, r, false);
    }

    private static void pass(int[] in, int[] out, int w, int h, int r, boolean rows) {
        int lines = rows ? h : w, len = rows ? w : h;
        for (int l = 0; l < lines; l++) {
            int sa = 0, sr = 0, sg = 0, sb = 0, n = 0;
            for (int k = -r; k <= r; k++) {
                int i = Math.max(0, Math.min(len - 1, k));
                int p = in[rows ? l * w + i : i * w + l];
                sa += p >>> 24; sr += (p >> 16) & 255; sg += (p >> 8) & 255; sb += p & 255; n++;
            }
            for (int k = 0; k < len; k++) {
                out[rows ? l * w + k : k * w + l] = (sa / n) << 24 | (sr / n) << 16 | (sg / n) << 8 | (sb / n);
                int o = Math.max(0, k - r), a = Math.min(len - 1, k + r + 1);
                int po = in[rows ? l * w + o : o * w + l], pa = in[rows ? l * w + a : a * w + l];
                sa += (pa >>> 24) - (po >>> 24);
                sr += ((pa >> 16) & 255) - ((po >> 16) & 255);
                sg += ((pa >> 8) & 255) - ((po >> 8) & 255);
                sb += (pa & 255) - (po & 255);
            }
        }
    }

    private final View host;
    private final Bitmap blur;
    private final float radius;
    private final int dim;
    private final Drawable over;
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);
    private final Paint dimPaint = new Paint();
    private final Path clip = new Path();
    private final int[] loc = new int[2];
    private final Rect src = new Rect();
    private final RectF dst = new RectF();

    /** [dim]: the wallpaper's darkening (0–255 alpha), as on the photo itself. */
    Frost(View host, Bitmap blur, float radius, int dim, Drawable over) {
        this.host = host;
        this.blur = blur;
        this.radius = radius;
        this.dim = dim;
        this.over = over;
        dimPaint.setColor(dim << 24);
    }

    @Override public void draw(Canvas c) {
        Rect b = getBounds();
        if (b.isEmpty()) return;
        try {
            host.getLocationInWindow(loc);
            float sx = host.getScaleX(), sy = host.getScaleY();
            int x = loc[0], y = loc[1];
            src.set((x + b.left) / SCALE, (y + b.top) / SCALE,
                    (x + Math.round(b.right * sx)) / SCALE, (y + Math.round(b.bottom * sy)) / SCALE);
            Bitmap pic = blur != null ? blur : liveBlur;
            if (pic != null) src.intersect(0, 0, pic.getWidth(), pic.getHeight());
            dst.set(b);
            clip.reset();
            clip.addRoundRect(dst, radius, radius, Path.Direction.CW);
            int save = c.save();
            c.clipPath(clip);
            if (pic != null && !src.isEmpty()) c.drawBitmap(pic, src, dst, paint);
            if (dim > 0) c.drawRect(dst, dimPaint);
            c.restoreToCount(save);
        } catch (Throwable ignored) {}
        over.setBounds(b);
        over.draw(c);
    }

    @Override public void setAlpha(int a) { paint.setAlpha(a); over.setAlpha(a); }
    @Override public void setColorFilter(ColorFilter cf) { paint.setColorFilter(cf); }
    @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
}
