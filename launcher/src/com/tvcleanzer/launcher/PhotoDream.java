package com.tvcleanzer.launcher;

import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.service.dreams.DreamService;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextClock;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Photo frame screensaver: the owner's photos (sent from the phone) one after another with a
 * soft cross-fade and a slow zoom, the time, date and weather in the corner. Without photos it
 * shows the home-screen photo, or else a dim clock that moves around (no burn-in).
 */
public class PhotoDream extends DreamService {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Random random = new Random();
    private Prefs prefs;
    private FrameLayout root;
    private ImageView[] views;
    private int front;               // which of the two image views is shown
    private List<File> photos = new ArrayList<>();
    private int index;
    private LinearLayout info;
    private TextView weather;
    private boolean clockOnly;

    private final Runnable next = new Runnable() {
        @Override public void run() {
            showNext();
            handler.postDelayed(this, prefs.photoSec() * 1000L);
        }
    };

    private final Runnable moveClock = new Runnable() {
        @Override public void run() {
            if (info == null || root == null) return;
            int w = root.getWidth() - info.getWidth(), h = root.getHeight() - info.getHeight();
            if (w > 0 && h > 0) {
                info.animate().alpha(0f).setDuration(600).withEndAction(() -> {
                    info.setTranslationX(random.nextInt(w));
                    info.setTranslationY(random.nextInt(h));
                    info.animate().alpha(1f).setDuration(900).start();
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
        prefs = new Prefs(this);

        photos = Photos.list(this);
        if (photos.isEmpty() && Wallpaper.exists(this)) photos.add(Wallpaper.file(this));
        clockOnly = photos.isEmpty();
        setScreenBright(!clockOnly);

        root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);
        views = new ImageView[2];
        for (int i = 0; i < 2; i++) {
            ImageView v = new ImageView(this);
            v.setScaleType(ImageView.ScaleType.CENTER_CROP);
            v.setAlpha(0f);
            root.addView(v, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            views[i] = v;
        }

        int screenW = getResources().getDisplayMetrics().widthPixels;
        int screenH = getResources().getDisplayMetrics().heightPixels;
        if (!clockOnly) {
            // a soft shade at the bottom keeps the time readable on bright photos
            View shade = new View(this);
            shade.setBackground(new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                    new int[]{0x99000000, 0x00000000}));
            root.addView(shade, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, Math.round(screenH * 0.4f), Gravity.BOTTOM));
        }

        info = new LinearLayout(this);
        info.setOrientation(LinearLayout.VERTICAL);
        TextClock clock = new TextClock(this);
        String fmt = prefs.clock24() ? "HH:mm" : "h:mm";
        clock.setFormat24Hour(fmt);
        clock.setFormat12Hour(fmt);
        clock.setTextSize(clockOnly ? 96 : 72);
        clock.setTextColor(clockOnly ? 0xCCFFFFFF : 0xFFFFFFFF);
        clock.setIncludeFontPadding(false);
        clock.setSingleLine(true);
        clock.setShadowLayer(16, 0, 2, 0x99000000);
        clock.setTypeface(Typeface.create(Prefs.CLOCK_FONTS[prefs.clockFont()], Typeface.NORMAL));
        info.addView(clock);
        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE, d MMMM");
        date.setFormat24Hour("EEEE, d MMMM");
        date.setTextSize(20);
        date.setTextColor(0xD9FFFFFF);
        date.setSingleLine(true);
        date.setShadowLayer(10, 0, 0, 0x99000000);
        date.setPadding(0, 0, Ui.dp(this, 6), 0);
        info.addView(date);
        weather = Ui.text(this, 18, 0xD9FFFFFF, "sans-serif-medium");
        weather.setShadowLayer(10, 0, 0, 0x99000000);
        LinearLayout.LayoutParams wl = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        wl.topMargin = Ui.dp(this, 4);
        info.addView(weather, wl);
        updateWeather();

        FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                clockOnly ? Gravity.TOP | Gravity.START : Gravity.BOTTOM | Gravity.START);
        if (!clockOnly) {
            ilp.leftMargin = Math.round(screenW * 0.05f);
            ilp.bottomMargin = Math.round(screenH * 0.07f);
        }
        root.addView(info, ilp);
        setContentView(root);
    }

    private void updateWeather() {
        String w = Weather.line(prefs);
        weather.setText(w == null ? "" : w);
        weather.setVisibility(w == null ? View.GONE : View.VISIBLE);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        if (clockOnly) {
            handler.post(moveClock);
        } else {
            index = random.nextInt(photos.size());
            handler.post(next);
        }
        io.execute(() -> {
            if (Weather.refreshIfStale(prefs)) handler.post(this::updateWeather);
        });
    }

    /** Decodes the next photo off the UI thread, then cross-fades to it. */
    private void showNext() {
        if (photos.isEmpty()) return;
        final File f = photos.get(index % photos.size());
        index++;
        io.execute(() -> {
            final Bitmap b = Photos.load(this, f);
            handler.post(() -> {
                if (b == null || views == null) return;
                ImageView in = views[1 - front], out = views[front];
                front = 1 - front;
                in.animate().cancel();
                in.setImageBitmap(b);
                in.setScaleX(1f);
                in.setScaleY(1f);
                boolean move = prefs.anim() != Prefs.ANIM_OFF;
                in.animate().alpha(1f).setDuration(move ? 1500 : 0).start();
                out.animate().alpha(0f).setDuration(move ? 1500 : 0).withEndAction(() -> {
                    out.setImageDrawable(null); // only one photo in memory
                }).start();
                if (move) {
                    // slow zoom across the photo's time on screen ("Ken Burns")
                    in.animate().scaleX(1.08f).scaleY(1.08f).setDuration(prefs.photoSec() * 1000L)
                            .setStartDelay(0).start();
                }
            });
        });
    }

    @Override
    public void onDreamingStopped() {
        handler.removeCallbacksAndMessages(null);
        super.onDreamingStopped();
    }

    @Override
    public void onDetachedFromWindow() {
        handler.removeCallbacksAndMessages(null);
        io.shutdownNow();
        views = null;
        super.onDetachedFromWindow();
    }
}
