package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/**
 * Top-bar button with a drawn glyph (no image assets), the compact twin of a Pill:
 * network (Wi-Fi arcs / Ethernet / VPN lock / none) in a status colour, Bluetooth, the TV's
 * settings or the gear.
 * Round: a 46 dp circle like the gear (owners who like it minimal asked for icons instead of
 * «Wi-Fi» and «Настройки ТВ»). Mini (0.68, the default): a small glyph in the screen's corner
 * with no circle, like a tablet's status bar; the network one carries a «VPN» badge; focus
 * shows a light capsule behind it.
 */
final class TopIcon extends View {
    static final int WIFI = Glyphs.WIFI, ETHERNET = Glyphs.ETHERNET, VPN = Glyphs.VPN, OFFLINE = Glyphs.OFFLINE,
            TV = Glyphs.TV, BT = Glyphs.BT, BT_OFF = Glyphs.BT_OFF, GEAR = Glyphs.GEAR;
    /** Bluetooth on with nothing connected: a quiet grey. */
    static final int IDLE = 0xFF9CA3AF;
    /** Green: online; orange: no network or no internet; blue: through a VPN. */
    static final int OK = 0xFF4ADE80, BAD = 0xFFFB923C, VPN_COLOR = 0xFF60A5FA, OFF = 0xFFF87171;

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final boolean mini;
    private int glyph;
    private int status; // 0 = no status dot
    private boolean vpn;

    TopIcon(Context c, int glyph, int status) { this(c, glyph, status, false); }

    TopIcon(Context c, int glyph, int status, boolean mini) {
        super(c);
        this.glyph = glyph;
        this.status = status;
        this.mini = mini;
        setFocusable(true);
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        text.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.BOLD));
        setOnFocusChangeListener((v, has) -> {
            float s = has ? (mini ? 1.1f : 1.15f) : 1f;
            animate().scaleX(s).scaleY(s).setDuration(160).start();
            invalidate();
        });
    }

    void set(int glyph, int status) {
        if (glyph == this.glyph && status == this.status) return;
        this.glyph = glyph;
        this.status = status;
        invalidate();
    }

    /** Mini network icon: the «VPN» badge after the glyph (the caller widens the view). */
    void setVpn(boolean on) {
        if (on == vpn) return;
        vpn = on;
        invalidate();
    }

    boolean vpn() { return vpn; }
    int glyph() { return glyph; }
    int status() { return status; }

    /** Width of a mini icon [h] high: the badge takes room after the glyph. */
    static int miniWidth(int h, boolean vpn) { return vpn ? Math.round(h * 2.35f) : h; }

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
        Glyphs.draw(c, glyph, cx, cy, w * (glyph == GEAR ? 0.34f : 0.30f), w, col, ink, fill);
    }

    private void drawMini(Canvas c) {
        float w = getWidth(), h = getHeight(), cy = h / 2f;
        boolean f = isFocused();
        if (f) {
            fill.setStyle(Paint.Style.FILL);
            fill.setColor(0xF2FFFFFF);
            c.drawRoundRect(new RectF(0, 0, w, h), h / 2f, h / 2f, fill);
        } else {
            // a soft shadow under the white glyph: readable over a bright photo
            ink.setShadowLayer(h * 0.12f, 0, 0, 0x80000000);
            fill.setShadowLayer(h * 0.12f, 0, 0, 0x80000000);
        }
        // white like a status bar; only trouble gets a colour (no internet, no network)
        int col = status == BAD || status == OFF ? status : (status == IDLE ? 0xB3FFFFFF : 0xF2FFFFFF);
        if (f) col = status == BAD || status == OFF ? darker(status) : 0xFF111111;
        float gx = vpn ? h * 0.5f + h * 0.1f : w / 2f;
        Glyphs.draw(c, glyph, gx, cy, h * (glyph == GEAR ? 0.34f : 0.31f), h * 1.25f, col, ink, fill);
        if (vpn) {
            // «VPN» in an outlined capsule, the glyph's colour
            text.setTextSize(h * 0.36f);
            text.setColor(col);
            float tw = text.measureText("VPN");
            float bx = h * 1.12f, bh = h * 0.56f, bw = tw + h * 0.34f;
            ink.setStyle(Paint.Style.STROKE);
            ink.setStrokeWidth(Math.max(1.5f, h * 0.06f));
            ink.setColor(col);
            c.drawRoundRect(new RectF(bx, cy - bh / 2, bx + bw, cy + bh / 2), bh * 0.32f, bh * 0.32f, ink);
            c.drawText("VPN", bx + (bw - tw) / 2f, cy - (text.ascent() + text.descent()) / 2f, text);
        }
        ink.clearShadowLayer();
        fill.clearShadowLayer();
    }

    private static int darker(int c) {
        int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
        return 0xFF000000 | (r * 7 / 10 << 16) | (g * 7 / 10 << 8) | (b * 7 / 10);
    }
}
