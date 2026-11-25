package com.tvcleanzer.launcher;

import android.content.Context;
import android.view.Gravity;
import android.widget.TextView;

/** Capsule button for the top bar (tvOS style): glassy at rest, white when focused. */
final class Pill extends TextView {
    Pill(Context c, CharSequence text) {
        super(c);
        setText(text);
        setTextSize(17);
        setTextColor(0xF2FFFFFF);
        setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        setGravity(Gravity.CENTER);
        setSingleLine(true);
        // 1.57: a long name («Bluetooth · HaierTV-RC») is cut with «…»: the row of pills ran off
        // the screen beside the clock's glass (Roman)
        setEllipsize(android.text.TextUtils.TruncateAt.END);
        setMaxWidth(Math.round(c.getResources().getDisplayMetrics().widthPixels * 0.17f));
        setIncludeFontPadding(false);
        int ph = Ui.dp(c, 18), pv = Ui.dp(c, 10);
        setPadding(ph, pv, ph, pv);
        setFocusable(true);
        // Android 8+ paints a grey "default focus highlight" over focusable views without a
        // focused-state background: on tiles it covered the colour ring ("рамка обрезается").
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        final float r = Ui.dp(c, 30);
        setBackground(Ui.glass(r));
        setOnFocusChangeListener((v, has) -> {
            setBackground(has ? Ui.round(0xFFFFFFFF, r) : Ui.glass(r));
            setTextColor(has ? 0xFF111111 : 0xF2FFFFFF);
            animate().scaleX(has ? 1.08f : 1f).scaleY(has ? 1.08f : 1f)
                    .translationZ(has ? Ui.dp(c, 8) : 0).setDuration(160).start();
        });
    }
}
