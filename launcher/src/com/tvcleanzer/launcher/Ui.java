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

    /** View.FOCUS_* for an arrow key, 0 for any other key. */
    static int focusDir(int keyCode) {
        switch (keyCode) {
            case android.view.KeyEvent.KEYCODE_DPAD_LEFT: return android.view.View.FOCUS_LEFT;
            case android.view.KeyEvent.KEYCODE_DPAD_RIGHT: return android.view.View.FOCUS_RIGHT;
            case android.view.KeyEvent.KEYCODE_DPAD_UP: return android.view.View.FOCUS_UP;
            case android.view.KeyEvent.KEYCODE_DPAD_DOWN: return android.view.View.FOCUS_DOWN;
            default: return 0;
        }
    }

    /** The system «click» when an arrow moved the focus (#10). Scroll views move the focus
     *  themselves and skip it, so rows inside them were silent. AudioManager plays it only
     *  when the TV's sound effects are on. */
    static void navSound(android.view.View before, android.view.View after, int dir) {
        if (dir == 0 || after == null || after == before) return;
        after.playSoundEffect(android.view.SoundEffectConstants.getContantForFocusDirection(dir));
    }

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

    /** The favourites shelf in the owner's chosen look ([Prefs.shelf]). */
    static GradientDrawable shelf(float radiusPx, int look) {
        GradientDrawable g = new GradientDrawable();
        g.setCornerRadius(radiusPx);
        if (look == Prefs.SHELF_CLEAR) {
            g.setColor(0x00000000);
        } else if (look == Prefs.SHELF_DARK) {
            g.setColor(0x73000000);
            g.setStroke(1, 0x1FFFFFFF);
        } else {
            g.setColor(0x1AFFFFFF);
            g.setStroke(1, 0x26FFFFFF);
        }
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
