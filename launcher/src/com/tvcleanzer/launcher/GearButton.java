package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.View;

/** Round focusable settings button with a gear drawn on canvas (no image assets). */
final class GearButton extends View {
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint gear = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int accent;

    GearButton(Context c, int accent) {
        super(c);
        this.accent = accent;
        setFocusable(true);
        // Android 8+ paints a grey "default focus highlight" over focusable views without a
        // focused-state background: on tiles it covered the colour ring ("рамка обрезается").
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        gear.setStyle(Paint.Style.STROKE);
        setOnFocusChangeListener((v, has) -> {
            animate().scaleX(has ? 1.15f : 1f).scaleY(has ? 1.15f : 1f).setDuration(160).start();
            invalidate();
        });
    }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth(), cx = w / 2f, cy = getHeight() / 2f;
        boolean f = hasFocus() || isFocused();
        fill.setColor(f ? 0xFFFFFFFF : 0x26FFFFFF);
        c.drawCircle(cx, cy, w / 2f, fill);

        // a solid gear (0.68): eight strokes round a ring read as a sun («солнышко»)
        gear.setStyle(Paint.Style.FILL);
        gear.setColor(f ? 0xFF111111 : 0xE6FFFFFF);
        c.drawPath(Glyphs.gear(cx, cy, w * 0.34f), gear);
    }
}
