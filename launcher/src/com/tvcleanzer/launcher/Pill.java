package com.tvcleanzer.launcher;

import android.content.Context;
import android.view.Gravity;
import android.widget.TextView;

/** Capsule button for the top bar (tvOS style): glassy at rest, white when focused. */
final class Pill extends TextView {
    Pill(Context c, String text) {
        super(c);
        setText(text);
        setTextSize(17);
        setTextColor(0xF2FFFFFF);
        setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        setGravity(Gravity.CENTER);
        setSingleLine(true);
        setIncludeFontPadding(false);
        int ph = Ui.dp(c, 22), pv = Ui.dp(c, 11);
        setPadding(ph, pv, ph, pv);
        setFocusable(true);
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
