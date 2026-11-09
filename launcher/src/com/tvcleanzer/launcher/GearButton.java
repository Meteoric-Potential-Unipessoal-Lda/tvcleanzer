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

        int col = f ? 0xFF111111 : 0xE6FFFFFF;
        gear.setColor(col);
        float r = w * 0.17f;
        gear.setStrokeWidth(w * 0.07f);
        c.drawCircle(cx, cy, r, gear);
        gear.setStrokeWidth(w * 0.09f);
        gear.setStrokeCap(Paint.Cap.ROUND);
        for (int i = 0; i < 8; i++) {
            double a = Math.PI / 4 * i;
            float x1 = cx + (float) Math.cos(a) * r * 1.45f, y1 = cy + (float) Math.sin(a) * r * 1.45f;
            float x2 = cx + (float) Math.cos(a) * r * 1.85f, y2 = cy + (float) Math.sin(a) * r * 1.85f;
            c.drawLine(x1, y1, x2, y2, gear);
        }
    }
}
