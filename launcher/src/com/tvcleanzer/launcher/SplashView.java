package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.SweepGradient;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.view.View;

/**
 * Loading screen shown while the launcher starts (after a TV reboot, after an update,
 * whenever Android had to start it again): logo with a spinning ring, name, author line.
 * Everything is drawn frame by frame from the clock, so it moves even on TVs where the
 * system animation scale is 0 (View animations would just jump there).
 */
final class SplashView extends View {

    static final String CREDIT = "Автор — Андрей Жердев · t.me/zherdyevofficial";

    private final Skin skin;
    private final long born = SystemClock.uptimeMillis();
    private long leaving;                  // 0 while shown; start of the fade-out
    private Runnable gone;

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint txt = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path star = new Path();
    private Shader bg;
    private int bw, bh;

    SplashView(Context c, Skin skin) {
        super(c);
        this.skin = skin;
        setFocusable(false);
        setClickable(false);
    }

    boolean leaving() { return leaving != 0; }

    /** Fades out over ~0.5 s, then calls [done] (which removes the view). */
    void dismiss(Runnable done) {
        if (leaving != 0) return;
        leaving = SystemClock.uptimeMillis();
        gone = done;
        postInvalidateOnAnimation();
    }

    /** Time since the splash appeared, for the "at least a moment" rule. */
    long age() { return SystemClock.uptimeMillis() - born; }

    private static float clamp(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
    private static float ease(float t) { t = clamp(t); return t * t * (3f - 2f * t); }
    private static int alpha(int color, float a) {
        return (color & 0x00FFFFFF) | (Math.round(((color >>> 24) & 0xFF) * clamp(a)) << 24);
    }

    @Override
    protected void onDraw(Canvas c) {
        final long now = SystemClock.uptimeMillis();
        final float t = (now - born) / 1000f;
        final float out = leaving == 0 ? 0f : ease((now - leaving) / 500f);
        final float all = 1f - out;
        final int w = getWidth(), h = getHeight();
        if (w == 0 || h == 0) { postInvalidateOnAnimation(); return; }
        final int acc = skin.accent;

        // background: the skin's gradient, so the home screen follows without a colour jump
        if (bg == null || bw != w || bh != h) {
            bg = new LinearGradient(0, 0, w * 0.4f, h, skin.bgTop, skin.bgBottom, Shader.TileMode.CLAMP);
            bw = w; bh = h;
        }
        p.setShader(bg);
        p.setAlpha(Math.round(255 * all));
        c.drawRect(0, 0, w, h, p);
        p.setShader(null);
        p.setAlpha(255);

        final float L = h * 0.19f;                 // logo tile size
        final float cx = w / 2f, cy = h * 0.43f;
        final float in = ease(t / 0.6f);           // entrance
        final float scale = (0.88f + 0.12f * in) * (1f + 0.06f * out);
        final float breath = 0.75f + 0.25f * (float) Math.sin(t * 2.2);

        // accent glow behind the logo
        float gr = L * 1.9f;
        p.setShader(new RadialGradient(cx, cy, gr,
                new int[]{alpha(acc | 0xFF000000, 0.30f * breath * in * all), alpha(acc | 0xFF000000, 0)},
                null, Shader.TileMode.CLAMP));
        c.drawCircle(cx, cy, gr, p);
        p.setShader(null);

        c.save();
        c.scale(scale, scale, cx, cy);

        // spinning ring: faint track + a bright arc that sweeps round
        float R = L * 0.86f;
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeCap(Paint.Cap.ROUND);
        p.setStrokeWidth(L * 0.03f);
        p.setColor(alpha(acc | 0xFF000000, 0.14f * in * all));
        c.drawCircle(cx, cy, R, p);
        float rot = (t * 300f) % 360f;
        float sweep = 70f + 50f * (float) Math.sin(t * 1.7);
        c.save();
        c.rotate(rot, cx, cy);
        p.setShader(new SweepGradient(cx, cy,
                new int[]{alpha(acc | 0xFF000000, 0), alpha(acc | 0xFF000000, in * all)},
                new float[]{0f, sweep / 360f}));
        r.set(cx - R, cy - R, cx + R, cy + R);
        c.drawArc(r, 0, sweep, false, p);
        p.setShader(null);
        c.restore();

        // logo tile
        p.setStyle(Paint.Style.FILL);
        p.setColor(alpha(0xFF0C1322, in * all));
        float half = L / 2f, rad = L * 0.24f;
        r.set(cx - half, cy - half, cx + half, cy + half);
        c.drawRoundRect(r, rad, rad, p);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(L * 0.012f);
        p.setColor(alpha(acc | 0xFF000000, 0.45f * in * all));
        c.drawRoundRect(r, rad, rad, p);

        // TV inside the tile
        p.setStrokeWidth(L * 0.055f);
        p.setColor(alpha(acc | 0xFF000000, in * all));
        float sw = L * 0.29f, sh = L * 0.19f, sy = cy - L * 0.05f;
        r.set(cx - sw, sy - sh, cx + sw, sy + sh);
        c.drawRoundRect(r, L * 0.06f, L * 0.06f, p);
        c.drawLine(cx, sy + sh, cx, sy + sh + L * 0.08f, p);
        c.drawLine(cx - L * 0.13f, sy + sh + L * 0.10f, cx + L * 0.13f, sy + sh + L * 0.10f, p);

        // sparkle on the screen: grows and turns; a small one outside twinkles
        p.setStyle(Paint.Style.FILL);
        float tw = 0.75f + 0.25f * (float) Math.sin(t * 3.1);
        drawStar(c, cx, sy, L * 0.14f * tw, t * 40f, alpha(0xFFFFFFFF, in * all));
        float tw2 = 0.5f + 0.5f * (float) Math.sin(t * 2.3 + 1.3);
        drawStar(c, cx + L * 0.36f, cy - L * 0.36f, L * 0.05f * (0.4f + 0.6f * tw2), -t * 30f,
                alpha(acc | 0xFF000000, tw2 * in * all));
        c.restore();

        // name
        float ty = cy + R + h * 0.10f;
        float ta = ease((t - 0.2f) / 0.6f) * all;
        txt.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        txt.setTextSize(h * 0.062f);
        String a = "TVClean", b = "zer";
        float wa = txt.measureText(a), wb = txt.measureText(b);
        float x0 = cx - (wa + wb) / 2f;
        txt.setColor(alpha(0xFFFFFFFF, ta));
        c.drawText(a, x0, ty, txt);
        txt.setColor(alpha(acc | 0xFF000000, ta));
        c.drawText(b, x0 + wa, ty, txt);

        txt.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        txt.setTextSize(h * 0.026f);
        txt.setLetterSpacing(0.32f);
        String sub = "LAUNCHER";
        txt.setColor(alpha(0xB3FFFFFF, ta));
        c.drawText(sub, cx - txt.measureText(sub) / 2f, ty + h * 0.055f, txt);
        txt.setLetterSpacing(0f);

        // who made it: small and quiet at the bottom
        float ca = ease((t - 0.5f) / 0.6f) * all;
        txt.setTextSize(h * 0.021f);
        txt.setColor(alpha(0x80FFFFFF, ca));
        c.drawText(CREDIT, cx - txt.measureText(CREDIT) / 2f, h * 0.93f, txt);

        if (leaving != 0 && out >= 1f) {
            Runnable g = gone;
            gone = null;
            if (g != null) post(g);
            return;
        }
        postInvalidateOnAnimation();
    }

    /** Four-pointed star, like the sparkle in the app icon. */
    private void drawStar(Canvas c, float x, float y, float s, float deg, int color) {
        star.reset();
        float k = s * 0.22f;
        star.moveTo(x, y - s);
        star.quadTo(x + k, y - k, x + s, y);
        star.quadTo(x + k, y + k, x, y + s);
        star.quadTo(x - k, y + k, x - s, y);
        star.quadTo(x - k, y - k, x, y - s);
        star.close();
        c.save();
        c.rotate(deg, x, y);
        p.setColor(color);
        c.drawPath(star, p);
        c.restore();
    }
}
