package com.tvcleanzer.launcher;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;

/**
 * The launcher's own line glyphs, drawn on canvas (no image assets, nobody's icon set):
 * network, Bluetooth, the TV's settings, a solid gear, «more» dots and an input.
 * TopIcon (round and corner icons), GearButton and the dock buttons share them.
 */
final class Glyphs {
    private Glyphs() {}

    static final int WIFI = 0, ETHERNET = 1, VPN = 2, OFFLINE = 3, TV = 4, BT = 5, BT_OFF = 6,
            GEAR = 7, MORE = 8, INPUT = 9;

    /**
     * Draws [glyph] centred on (cx, cy), [s] = half its size, in [col].
     * [w] is the stroke basis (the button's width for round buttons).
     */
    static void draw(Canvas c, int glyph, float cx, float cy, float s, float w, int col, Paint ink, Paint fill) {
        ink.setColor(col);
        ink.setStyle(Paint.Style.STROKE);
        ink.setStrokeCap(Paint.Cap.ROUND);
        ink.setStrokeJoin(Paint.Join.ROUND);
        ink.setStrokeWidth(w * 0.065f);
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(col);
        switch (glyph) {
            case WIFI:
            case OFFLINE: {
                float by = cy + s * 0.75f;
                for (int i = 1; i <= 3; i++) {
                    float r = s * 0.55f * i;
                    c.drawArc(new RectF(cx - r, by - r, cx + r, by + r), 225, 90, false, ink);
                }
                c.drawCircle(cx, by - s * 0.05f, w * 0.05f, fill);
                if (glyph == OFFLINE) c.drawLine(cx - s, cy - s, cx + s, cy + s, ink);
                break;
            }
            case ETHERNET: {
                // a plug: square socket with three pins
                RectF r = new RectF(cx - s * 0.8f, cy - s * 0.55f, cx + s * 0.8f, cy + s * 0.75f);
                c.drawRoundRect(r, w * 0.04f, w * 0.04f, ink);
                for (int i = -1; i <= 1; i++) c.drawLine(cx + i * s * 0.4f, cy - s * 0.2f, cx + i * s * 0.4f, cy + s * 0.25f, ink);
                c.drawLine(cx, cy - s * 0.55f, cx, cy - s, ink);
                break;
            }
            case VPN: {
                // a padlock
                RectF body = new RectF(cx - s * 0.75f, cy - s * 0.1f, cx + s * 0.75f, cy + s * 0.9f);
                c.drawRoundRect(body, w * 0.05f, w * 0.05f, ink);
                RectF arc = new RectF(cx - s * 0.48f, cy - s * 0.95f, cx + s * 0.48f, cy + s * 0.1f);
                c.drawArc(arc, 180, 180, false, ink);
                c.drawCircle(cx, cy + s * 0.38f, w * 0.045f, fill);
                break;
            }
            case BT:
            case BT_OFF: {
                // the Bluetooth rune: a vertical line with two arrowheads to the right
                float t = cy - s, b = cy + s, x0 = cx - s * 0.12f, r = cx + s * 0.45f, l = cx - s * 0.55f;
                Path p = new Path();
                p.moveTo(l, cy - s * 0.5f);
                p.lineTo(r, cy + s * 0.5f);
                p.lineTo(x0, b);
                p.lineTo(x0, t);
                p.lineTo(r, cy - s * 0.5f);
                p.lineTo(l, cy + s * 0.5f);
                c.drawPath(p, ink);
                if (glyph == BT_OFF) c.drawLine(cx - s, cy - s, cx + s, cy + s, ink);
                break;
            }
            case GEAR: {
                // a solid gear with a hole (the old one, eight strokes round a ring, read as a sun)
                c.drawPath(gear(cx, cy, s), fill);
                break;
            }
            case MORE: {
                float r = s * 0.16f;
                for (int i = -1; i <= 1; i++) c.drawCircle(cx + i * s * 0.62f, cy, r, fill);
                break;
            }
            case INPUT: {
                // a screen with an arrow coming in from the left
                RectF scr = new RectF(cx - s * 0.55f, cy - s * 0.8f, cx + s, cy + s * 0.8f);
                c.drawRoundRect(scr, w * 0.05f, w * 0.05f, ink);
                c.drawLine(cx - s, cy, cx + s * 0.3f, cy, ink);
                c.drawLine(cx + s * 0.3f, cy, cx - s * 0.05f, cy - s * 0.35f, ink);
                c.drawLine(cx + s * 0.3f, cy, cx - s * 0.05f, cy + s * 0.35f, ink);
                break;
            }
            default: { // TV: a screen on a stand with two slider knobs
                RectF scr = new RectF(cx - s, cy - s * 0.75f, cx + s, cy + s * 0.55f);
                c.drawRoundRect(scr, w * 0.04f, w * 0.04f, ink);
                c.drawLine(cx - s * 0.45f, cy + s * 0.95f, cx + s * 0.45f, cy + s * 0.95f, ink);
                ink.setStrokeWidth(w * 0.05f);
                c.drawLine(cx - s * 0.55f, cy - s * 0.3f, cx + s * 0.55f, cy - s * 0.3f, ink);
                c.drawLine(cx - s * 0.55f, cy + s * 0.15f, cx + s * 0.55f, cy + s * 0.15f, ink);
                c.drawCircle(cx + s * 0.2f, cy - s * 0.3f, w * 0.05f, fill);
                c.drawCircle(cx - s * 0.25f, cy + s * 0.15f, w * 0.05f, fill);
                break;
            }
        }
    }

    /** Eight teeth round a body, a hole in the middle (even-odd fill). */
    static Path gear(float cx, float cy, float s) {
        Path p = new Path();
        int n = 8;
        float ro = s, ri = s * 0.74f;
        double step = Math.PI * 2 / n, tip = step * 0.20, base = step * 0.31;
        for (int i = 0; i < n; i++) {
            double a = step * i - Math.PI / 2;
            float x0 = cx + (float) (Math.cos(a - base) * ri), y0 = cy + (float) (Math.sin(a - base) * ri);
            if (i == 0) p.moveTo(x0, y0); else p.lineTo(x0, y0);
            p.lineTo(cx + (float) (Math.cos(a - tip) * ro), cy + (float) (Math.sin(a - tip) * ro));
            p.lineTo(cx + (float) (Math.cos(a + tip) * ro), cy + (float) (Math.sin(a + tip) * ro));
            p.lineTo(cx + (float) (Math.cos(a + base) * ri), cy + (float) (Math.sin(a + base) * ri));
        }
        p.close();
        p.addCircle(cx, cy, s * 0.32f, Path.Direction.CW);
        p.setFillType(Path.FillType.EVEN_ODD);
        return p;
    }

    /** A dock button's face: a grey glass square (or circle) with a white glyph, the size of an
     *  app icon next to it (owners: «Все приложения» and the gear as icons, not words). */
    static final class Face extends Drawable {
        private final int glyph;
        private final boolean round;
        private final Paint bg = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);

        Face(int glyph, boolean round) {
            this.glyph = glyph;
            this.round = round;
        }

        @Override public void draw(Canvas c) {
            android.graphics.Rect b = getBounds();
            float w = b.width(), h = b.height(), cx = b.exactCenterX(), cy = b.exactCenterY();
            bg.setShader(new android.graphics.LinearGradient(0, b.top, 0, b.bottom,
                    0xFF6B7280, 0xFF4B5563, android.graphics.Shader.TileMode.CLAMP));
            if (round) c.drawCircle(cx, cy, Math.min(w, h) / 2f, bg);
            else c.drawRect(b, bg);
            float s = Math.min(w, h) * (glyph == MORE ? 0.30f : 0.27f);
            Glyphs.draw(c, glyph, cx, cy, s, Math.min(w, h) * 0.7f, 0xF2FFFFFF, ink, fill);
        }

        @Override public void setAlpha(int a) { bg.setAlpha(a); ink.setAlpha(a); fill.setAlpha(a); }
        @Override public void setColorFilter(ColorFilter cf) {}
        @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
    }
}
