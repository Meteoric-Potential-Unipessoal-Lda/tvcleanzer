package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.widget.TextView;

/** Tiny helpers: no XML layouts, everything is built in code (fast start, tiny APK). */
final class Ui {
    private Ui() {}

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    static GradientDrawable round(int color, float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radiusPx);
        return g;
    }

    static GradientDrawable ring(int color, int strokePx, float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(0x00000000);
        g.setStroke(strokePx, color);
        g.setCornerRadius(radiusPx);
        return g;
    }

    /** Frosted-glass look: light translucent fill + hairline border. */
    static GradientDrawable glass(float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(0x1AFFFFFF);
        g.setStroke(1, 0x26FFFFFF);
        g.setCornerRadius(radiusPx);
        return g;
    }

    /** Darkens the bottom of the screen for depth (keeps any skin calm on bright TVs). */
    static GradientDrawable vignette() {
        return new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0x00000000, 0x33000000, 0x8C000000});
    }

    static GradientDrawable background(Skin s) {
        return new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{s.bgTop, s.bgBottom});
    }

    /** Soft round glow of the accent colour, used behind the clock. */
    static GradientDrawable glow(int accent, float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        g.setGradientRadius(radiusPx);
        g.setColors(new int[]{withAlpha(accent, 0x2E), withAlpha(accent, 0)});
        return g;
    }

    static int withAlpha(int color, int alpha) {
        return (color & 0x00FFFFFF) | (alpha << 24);
    }

    static TextView text(Context c, float sp, int color, String family) {
        TextView t = new TextView(c);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(family, Typeface.NORMAL));
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setIncludeFontPadding(false);
        return t;
    }
}
