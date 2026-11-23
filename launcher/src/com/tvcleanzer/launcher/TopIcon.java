package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/**
 * Top-bar button with a glyph (Glyphs: the icon pack and canvas glyphs), the compact twin of
 * a Pill: network in a status colour, the VPN plate, Bluetooth, the TV's settings or the gear.
 * Round: a 46 dp circle like the gear (owners who like it minimal asked for icons instead of
 * «Wi-Fi» and «Настройки ТВ»). Mini (0.68, the default): a white symbol in the corner panel
 * (one shared glass under all of them, HomeActivity.corner); focus is a white rounded frame
 * with a light fill, the symbol stays white (the icon pack's «remote focus»).
 */
final class TopIcon extends View {
    static final int WIFI = Glyphs.WIFI, ETHERNET = Glyphs.ETHERNET, VPN = Glyphs.VPN, OFFLINE = Glyphs.OFFLINE,
            TV = Glyphs.TV, BT = Glyphs.BT, BT_OFF = Glyphs.BT_OFF, GEAR = Glyphs.GEAR, VPN_PLATE = Glyphs.VPN_PLATE,
            MEM = Glyphs.MEM;

    /** Told when the icon gets or loses the focus (the memory icon shows its numbers then). */
    interface FocusHook { void focused(boolean has); }
    FocusHook hook;
    /** Bluetooth on with nothing connected: a quiet grey. */
    static final int IDLE = 0xFF9CA3AF;
    /** Green: online; orange: no network or no internet; blue: through a VPN. */
    static final int OK = 0xFF4ADE80, BAD = 0xFFFB923C, VPN_COLOR = 0xFF60A5FA, OFF = 0xFFF87171;

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final boolean mini;
    private int glyph;
    private int status; // 0 = no status dot

    TopIcon(Context c, int glyph, int status) { this(c, glyph, status, false); }

    TopIcon(Context c, int glyph, int status, boolean mini) {
        super(c);
        Glyphs.init(c);
        this.glyph = glyph;
        this.status = status;
        this.mini = mini;
        setFocusable(true);
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        setOnFocusChangeListener((v, has) -> {
            float s = has ? (mini ? 1.06f : 1.15f) : 1f;
            animate().scaleX(s).scaleY(s).setDuration(160).start();
            invalidate();
            if (hook != null) hook.focused(has);
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
        if (mini) { drawMini(c); return; }
        float w = getWidth(), h = getHeight(), cx = w / 2f, cy = h / 2f;
        boolean f = isFocused();
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(f ? 0xFFFFFFFF : 0x26FFFFFF);
        c.drawCircle(cx, cy, w / 2f, fill);
        // the glyph itself in the status colour (white when there is no status)
        int col = status != 0 ? status : (f ? 0xFF111111 : 0xE6FFFFFF);
        if (f && status != 0) col = darker(status);
        Glyphs.draw(c, glyph, cx, cy, w * 0.30f, w, col, ink, fill);
    }

    private void drawMini(Canvas c) {
        float w = getWidth(), h = getHeight(), cx = w / 2f, cy = h / 2f;
        if (isFocused()) {
            // the pack's remote focus: a white frame, a light fill, the symbol stays white
            float sw = Math.max(2f, h * 0.035f);
            RectF r = new RectF(sw / 2, sw / 2, w - sw / 2, h - sw / 2);
            float rad = h * 0.31f;
            fill.setStyle(Paint.Style.FILL);
            fill.setColor(0x21FFFFFF);
            c.drawRoundRect(r, rad, rad, fill);
            fill.setStyle(Paint.Style.STROKE);
            fill.setStrokeWidth(sw);
            fill.setColor(0xE6FFFFFF);
            c.drawRoundRect(r, rad, rad, fill);
        }
        // a traffic light (0.75, the owner: «главное, чтобы был светофор»): green all right,
        // orange trouble, red down, blue a device / VPN, grey off; white where there is no state
        int col = status == IDLE ? 0x99FFFFFF : status != 0 ? status : 0xF2FFFFFF;
        float s = h * 0.3f;
        // canvas glyphs in the pack's weight (≈ 2.2 units of 26)
        Glyphs.draw(c, glyph, cx, cy, s, s * 2.6f, col, ink, fill);
    }

    private static int darker(int c) {
        int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
        return 0xFF000000 | (r * 7 / 10 << 16) | (g * 7 / 10 << 8) | (b * 7 / 10);
    }
}
