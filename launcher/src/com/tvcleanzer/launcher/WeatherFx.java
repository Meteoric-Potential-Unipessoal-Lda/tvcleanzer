package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.os.SystemClock;
import android.view.View;

import java.util.Random;

/**
 * 1.46 «Погода на обоях» (an idea from couch-tv's ambient weather, written for a native view):
 * rain, snow, fog or a storm drawn over the wallpaper, under the home's content, by the weather
 * code the launcher already has. Light on purpose: at most 70 strokes, about 30 frames a second,
 * nothing at all while the home is not on screen or animations are off. Off by default.
 */
final class WeatherFx extends View {
    static final int NONE = 0, DRIZZLE = 1, RAIN = 2, SNOW = 3, FOG = 4, STORM = 5;

    /** What to draw for a WMO code (Open-Meteo / met.no through Weather.wmo). */
    static int kind(int code) {
        if (code == 45 || code == 48) return FOG;
        if (code >= 95) return STORM;
        if ((code >= 71 && code <= 77) || code == 85 || code == 86) return SNOW;
        if (code >= 51 && code <= 57) return DRIZZLE;
        if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return RAIN;
        return NONE;
    }

    private final int kind;
    private final Random rnd = new Random();
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private float[] px, py, sp, sz;
    private long last;
    private long flashAt, nextFlash;
    private boolean running;
    /** 1.67: fog as a soft picture drawn scaled, not a gradient per frame: on a TV (BlatikShin)
     *  the gradients burnt the screen white in one place and left a dark patch in another. */
    private Bitmap fogBlob;
    private final Paint blob = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final RectF dst = new RectF();

    private Bitmap fogBlob() {
        if (fogBlob == null) {
            int s = 64;
            fogBlob = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888);
            Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
            p.setShader(new RadialGradient(s / 2f, s / 2f, s / 2f, new int[]{0xFFFFFFFF, 0x66FFFFFF, 0x00FFFFFF},
                    new float[]{0f, 0.45f, 1f}, Shader.TileMode.CLAMP));
            new Canvas(fogBlob).drawCircle(s / 2f, s / 2f, s / 2f, p);
        }
        return fogBlob;
    }

    WeatherFx(Context c, int kind) {
        super(c);
        this.kind = kind;
        setWillNotDraw(false);
        setFocusable(false);
        setClickable(false);
        ink.setStrokeCap(Paint.Cap.ROUND);
    }

    void start() {
        if (kind == NONE || running) return;
        running = true;
        last = SystemClock.uptimeMillis();
        postInvalidateOnAnimation();
    }

    void stop() { running = false; }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        int n = kind == SNOW ? 45 : kind == RAIN || kind == STORM ? 70 : kind == DRIZZLE ? 35 : kind == FOG ? 6 : 0;
        px = new float[n]; py = new float[n]; sp = new float[n]; sz = new float[n];
        for (int i = 0; i < n; i++) seed(i, w, h, true);
        nextFlash = SystemClock.uptimeMillis() + 4000 + rnd.nextInt(8000);
    }

    private void seed(int i, int w, int h, boolean anywhere) {
        float d = getResources().getDisplayMetrics().density;
        px[i] = rnd.nextFloat() * w * (kind == FOG ? 1.2f : 1.1f) - (kind == FOG ? w * 0.1f : 0);
        py[i] = anywhere ? rnd.nextFloat() * h : -rnd.nextFloat() * h * 0.2f;
        switch (kind) {
            case SNOW: sp[i] = (25 + rnd.nextFloat() * 45) * d; sz[i] = (1.5f + rnd.nextFloat() * 2.5f) * d; break;
            case FOG: sp[i] = (6 + rnd.nextFloat() * 10) * d; sz[i] = h * (0.2f + rnd.nextFloat() * 0.15f);
                py[i] = h * (0.45f + rnd.nextFloat() * 0.5f); break; // 1.67: lower, smaller
            case DRIZZLE: sp[i] = (300 + rnd.nextFloat() * 150) * d; sz[i] = (8 + rnd.nextFloat() * 8) * d; break;
            default: sp[i] = (520 + rnd.nextFloat() * 260) * d; sz[i] = (14 + rnd.nextFloat() * 16) * d;
        }
    }

    @Override
    protected void onDraw(Canvas c) {
        if (!running || px == null) return;
        long now = SystemClock.uptimeMillis();
        float dt = Math.min(0.1f, (now - last) / 1000f);
        last = now;
        int w = getWidth(), h = getHeight();
        float d = getResources().getDisplayMetrics().density;
        for (int i = 0; i < px.length; i++) {
            switch (kind) {
                case SNOW:
                    py[i] += sp[i] * dt;
                    px[i] += (float) Math.sin((now / 1000.0) + i) * 12 * d * dt;
                    fill.setColor(0xB3FFFFFF);
                    c.drawCircle(px[i], py[i], sz[i], fill);
                    break;
                case FOG: {
                    px[i] += sp[i] * dt;
                    float r = sz[i] * 1.6f;
                    if (px[i] - r > w) px[i] = -r;
                    // a flat wisp, about a tenth white at its heart (was a fifth, in a circle)
                    dst.set(px[i] - r, py[i] - r * 0.45f, px[i] + r, py[i] + r * 0.45f);
                    blob.setAlpha(28);
                    c.drawBitmap(fogBlob(), null, dst, blob);
                    continue;
                }
                default:
                    py[i] += sp[i] * dt;
                    px[i] -= sp[i] * 0.12f * dt;
                    ink.setColor(kind == DRIZZLE ? 0x59D6E4FF : 0x73D6E4FF);
                    ink.setStrokeWidth((kind == DRIZZLE ? 1f : 1.4f) * d);
                    c.drawLine(px[i], py[i], px[i] + sz[i] * 0.12f, py[i] - sz[i], ink);
            }
            if (py[i] - sz[i] > h || px[i] < -w * 0.1f) seed(i, w, h, false);
        }
        if (kind == STORM) {
            if (now >= nextFlash) {
                flashAt = now;
                nextFlash = now + 5000 + rnd.nextInt(9000);
            }
            long f = now - flashAt;
            if (f < 450) {
                // two quick flashes, as lightning does
                int a = f < 90 ? 70 : f < 160 ? 0 : f < 260 ? 45 : 0;
                if (a > 0) c.drawColor(a << 24 | 0xFFFFFF);
            }
        }
        // about 30 frames a second: the TV's chip has other work
        postInvalidateDelayed(33);
    }
}
