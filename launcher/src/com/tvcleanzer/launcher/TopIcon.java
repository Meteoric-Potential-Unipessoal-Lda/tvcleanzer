package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/**
 * Round top-bar button with a drawn glyph (no image assets), the compact twin of a Pill:
 * network (Wi-Fi arcs / Ethernet / VPN lock / none) in a status colour, or the TV's settings.
 * Owners who like it minimal asked for icons instead of «Wi-Fi» and «Настройки ТВ».
 */
final class TopIcon extends View {
    static final int WIFI = 0, ETHERNET = 1, VPN = 2, OFFLINE = 3, TV = 4;
    /** Green: online; orange: no network or no internet; blue: through a VPN. */
    static final int OK = 0xFF4ADE80, BAD = 0xFFFB923C, VPN_COLOR = 0xFF60A5FA, OFF = 0xFFF87171;

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private int glyph;
    private int status; // 0 = no status dot

    TopIcon(Context c, int glyph, int status) {
        super(c);
        this.glyph = glyph;
        this.status = status;
        setFocusable(true);
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        ink.setStrokeCap(Paint.Cap.ROUND);
        ink.setStrokeJoin(Paint.Join.ROUND);
        setOnFocusChangeListener((v, has) -> {
            animate().scaleX(has ? 1.15f : 1f).scaleY(has ? 1.15f : 1f).setDuration(160).start();
            invalidate();
        });
    }

    void set(int glyph, int status) {
        if (glyph == this.glyph && status == this.status) return;
        this.glyph = glyph;
        this.status = status;
        invalidate();
    }

    int glyph() { return glyph; }
    int status() { return status; }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth(), h = getHeight(), cx = w / 2f, cy = h / 2f;
        boolean f = isFocused();
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(f ? 0xFFFFFFFF : 0x26FFFFFF);
        c.drawCircle(cx, cy, w / 2f, fill);
        // the glyph itself in the status colour (white when there is no status)
        int col = status != 0 ? status : (f ? 0xFF111111 : 0xE6FFFFFF);
        if (f && status != 0) col = darker(status);
        ink.setColor(col);
        ink.setStyle(Paint.Style.STROKE);
        float s = w * 0.30f; // glyph half-size
        ink.setStrokeWidth(w * 0.065f);
        switch (glyph) {
            case WIFI:
            case OFFLINE: {
                float by = cy + s * 0.75f;
                for (int i = 1; i <= 3; i++) {
                    float r = s * 0.55f * i;
                    c.drawArc(new RectF(cx - r, by - r, cx + r, by + r), 225, 90, false, ink);
                }
                fill.setColor(col);
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
                fill.setColor(col);
                c.drawCircle(cx, cy + s * 0.38f, w * 0.045f, fill);
                break;
            }
            default: { // TV: a screen on a stand with two slider knobs
                RectF scr = new RectF(cx - s, cy - s * 0.75f, cx + s, cy + s * 0.55f);
                c.drawRoundRect(scr, w * 0.04f, w * 0.04f, ink);
                c.drawLine(cx - s * 0.45f, cy + s * 0.95f, cx + s * 0.45f, cy + s * 0.95f, ink);
                ink.setStrokeWidth(w * 0.05f);
                c.drawLine(cx - s * 0.55f, cy - s * 0.3f, cx + s * 0.55f, cy - s * 0.3f, ink);
                c.drawLine(cx - s * 0.55f, cy + s * 0.15f, cx + s * 0.55f, cy + s * 0.15f, ink);
                fill.setColor(col);
                c.drawCircle(cx + s * 0.2f, cy - s * 0.3f, w * 0.05f, fill);
                c.drawCircle(cx - s * 0.25f, cy + s * 0.15f, w * 0.05f, fill);
                break;
            }
        }
    }

    private static int darker(int c) {
        int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
        return 0xFF000000 | (r * 7 / 10 << 16) | (g * 7 / 10 << 8) | (b * 7 / 10);
    }
}
