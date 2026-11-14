package com.tvcleanzer.launcher;

import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.service.dreams.DreamService;
import android.view.Gravity;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextClock;

import java.util.Random;

/**
 * Screensaver: a dim clock and date on black that moves to a new spot every
 * minute (no burn-in on OLED/plasma panels). The phone app makes it the TV's
 * screensaver when the firmware's own one (Yandex, Sber, …) is removed, because
 * some firmwares re-enable a removed screensaver while it is still the selected one.
 */
public class ClockDream extends DreamService {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Random random = new Random();
    private LinearLayout box;
    private FrameLayout root;

    private final Runnable move = new Runnable() {
        @Override public void run() {
            if (box == null || root == null) return;
            int w = root.getWidth() - box.getWidth(), h = root.getHeight() - box.getHeight();
            if (w > 0 && h > 0) {
                box.animate().alpha(0f).setDuration(600).withEndAction(() -> {
                    box.setTranslationX(random.nextInt(w));
                    box.setTranslationY(random.nextInt(h));
                    box.animate().alpha(1f).setDuration(900).start();
                }).start();
            }
            handler.postDelayed(this, 60_000);
        }
    };

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false);
        setFullscreen(true);
        setScreenBright(false);

        Prefs prefs = new Prefs(this);
        Skin skin = prefs.skin();

        root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);

        box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER_HORIZONTAL);

        TextClock clock = new TextClock(this);
        String fmt = prefs.clock24() ? "HH:mm" : "h:mm";
        clock.setFormat24Hour(fmt);
        clock.setFormat12Hour(fmt);
        clock.setTextSize(96);
        clock.setTextColor(0xCCFFFFFF);
        clock.setIncludeFontPadding(false);
        clock.setTypeface(Typeface.create("sans-serif-thin", Typeface.NORMAL));
        box.addView(clock);

        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE, d MMMM");
        date.setFormat24Hour("EEEE, d MMMM");
        date.setAllCaps(true);
        date.setLetterSpacing(0.14f);
        date.setTextSize(16);
        date.setTextColor((skin.accent & 0x00FFFFFF) | 0x99000000);
        date.setGravity(Gravity.CENTER_HORIZONTAL);
        box.addView(date);

        root.addView(box, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT));
        setContentView(root);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        handler.post(move);
    }

    @Override
    public void onDreamingStopped() {
        handler.removeCallbacks(move);
        super.onDreamingStopped();
    }

    @Override
    public void onDetachedFromWindow() {
        handler.removeCallbacks(move);
        super.onDetachedFromWindow();
    }
}
