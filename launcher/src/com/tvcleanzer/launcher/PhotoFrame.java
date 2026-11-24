package com.tvcleanzer.launcher;

import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.content.Context;
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
 * The photo frame itself: the owner's photos (sent from the phone) one after another with a
 * soft cross-fade and a slow zoom, the time, date and weather in the corner. Without photos it
 * shows the home-screen photo, or else a dim clock that moves around (no burn-in).
 *
 * 1.24: out of PhotoDream so that FrameActivity can show the same frame when the TV will not
 * start its screensaver on request (Xiaomi MiTV-AFKR0, Android 14: «Показать сейчас» refused).
 */
final class PhotoFrame {
    private final Context ctx;
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
    private View shade;
    private boolean clockOnly;
    private boolean started;

    PhotoFrame(Context ctx) { this.ctx = ctx; }

    /** No photos: only the moving clock (the dream dims the screen then). */
    boolean clockOnly() { return clockOnly; }

    // ── Music (0.61+): the owner's tracks, shuffled, while the frame is on screen ──
    private android.media.MediaPlayer player;
    private List<File> tracks;
    private int track;
    private int failures;
    private float level;

    private final Runnable musicFade = new Runnable() {
        @Override public void run() {
            if (player == null) return;
            level = Math.min(1f, level + 0.05f);
            try { player.setVolume(level, level); } catch (Exception ignored) {}
            if (level < 1f) handler.postDelayed(this, 100);
        }
    };

    private void startMusic() {
        if (!prefs.frameMusic()) return;
        tracks = Music.list(ctx);
        if (tracks.isEmpty()) return;
        java.util.Collections.shuffle(tracks, random);
        track = 0;
        failures = 0;
        level = 0f;
        play();
    }

    /** Plays [track]; a file that won't play is skipped, and after a full round of them the music stops. */
    private void play() {
        if (tracks == null || tracks.isEmpty()) return;
        while (failures < tracks.size()) {
            File f = tracks.get(track % tracks.size());
            track++;
            android.media.MediaPlayer m = new android.media.MediaPlayer();
            try {
                m.setAudioAttributes(new android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build());
                m.setDataSource(f.getAbsolutePath());
                m.prepare();
                m.setVolume(level, level);
                m.setOnCompletionListener(mp -> {
                    failures = 0;
                    release(mp);
                    play();
                });
                m.setOnErrorListener((mp, what, extra) -> {
                    failures++;
                    release(mp);
                    handler.post(this::play);
                    return true;
                });
                m.start();
                player = m;
                handler.removeCallbacks(musicFade);
                handler.post(musicFade);
                return;
            } catch (Exception e) {
                failures++;
                m.release();
            }
        }
    }

    private void release(android.media.MediaPlayer mp) {
        if (player == mp) player = null;
        try { mp.release(); } catch (Exception ignored) {}
    }

    private void stopMusic() {
        android.media.MediaPlayer m = player;
        player = null;
        tracks = null;
        if (m != null) {
            try { m.stop(); } catch (Exception ignored) {}
            m.release();
        }
    }

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

    /** Builds the frame's views; [start] sets them going. */
    View build() {
        prefs = new Prefs(ctx);

        photos = Photos.list(ctx);
        if (photos.isEmpty() && Wallpaper.exists(ctx)) photos.add(Wallpaper.file(ctx));
        clockOnly = photos.isEmpty();

        root = new FrameLayout(ctx);
        root.setBackgroundColor(0xFF000000);
        views = new ImageView[2];
        for (int i = 0; i < 2; i++) {
            ImageView v = new ImageView(ctx);
            v.setScaleType(ImageView.ScaleType.CENTER_CROP);
            v.setAlpha(0f);
            root.addView(v, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            views[i] = v;
        }

        int screenW = ctx.getResources().getDisplayMetrics().widthPixels;
        int screenH = ctx.getResources().getDisplayMetrics().heightPixels;
        if (!clockOnly) {
            // a soft shade at the bottom keeps the time readable on bright photos
            shade = new View(ctx);
            shade.setBackground(new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                    new int[]{0x99000000, 0x00000000}));
            root.addView(shade, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, Math.round(screenH * 0.4f), Gravity.BOTTOM));
        }

        info = new LinearLayout(ctx);
        info.setOrientation(LinearLayout.VERTICAL);
        TextClock clock = new TextClock(ctx);
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
        TextClock date = new TextClock(ctx);
        date.setFormat12Hour("EEEE, d MMMM");
        date.setFormat24Hour("EEEE, d MMMM");
        date.setTextSize(20);
        date.setTextColor(0xD9FFFFFF);
        date.setSingleLine(true);
        date.setShadowLayer(10, 0, 0, 0x99000000);
        date.setPadding(0, 0, Ui.dp(ctx, 6), 0);
        // The corner is sized before TextClock fills in its text, so the date got cut
        // ("понедельник, 16 ноя"): reserve room for the longest day name of the week ahead.
        date.setMinWidth(longestDate(date) + Ui.dp(ctx, 12));
        info.addView(date);
        weather = Ui.text(ctx, 18, 0xD9FFFFFF, "sans-serif-medium");
        weather.setShadowLayer(10, 0, 0, 0x99000000);
        LinearLayout.LayoutParams wl = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        wl.topMargin = Ui.dp(ctx, 4);
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
        return root;
    }

    private static int longestDate(TextView v) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("EEEE, d MMMM", java.util.Locale.getDefault());
        java.util.Calendar c = java.util.Calendar.getInstance();
        float max = 0;
        for (int i = 0; i < 7; i++) {
            max = Math.max(max, v.getPaint().measureText(f.format(c.getTime())));
            c.add(java.util.Calendar.DAY_OF_MONTH, 1);
        }
        return Math.round(max * 1.1f);
    }

    private void updateWeather() {
        String w = Weather.line(prefs);
        weather.setText(w == null ? "" : w);
        weather.setVisibility(w == null ? View.GONE : View.VISIBLE);
    }

    void start() {
        if (started || views == null) return;
        started = true;
        if (clockOnly) {
            handler.post(moveClock);
        } else {
            index = random.nextInt(photos.size());
            handler.post(next);
        }
        io.execute(() -> {
            if (Weather.refreshIfStale(prefs)) handler.post(this::updateWeather);
        });
        startMusic();
    }

    // Our own frame-by-frame fade and zoom: View animations obey the TV's "animation scale",
    // which TVCleanzer's boost halves and many owners turn off, so the photos "clicked".
    private static final long FADE_MS = 2500;
    private ImageView fadeIn, fadeOut, zoomView;
    private long fadeStart, zoomStart, zoomMs;
    private boolean zoom;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = android.os.SystemClock.uptimeMillis();
            boolean more = false;
            if (fadeIn != null) {
                float t = Math.min(1f, (now - fadeStart) / (float) FADE_MS);
                float e = t * t * (3f - 2f * t); // smoothstep: soft start and end
                fadeIn.setAlpha(e);
                if (fadeOut != null) fadeOut.setAlpha(1f - e);
                if (t >= 1f) {
                    if (fadeOut != null) { fadeOut.setImageDrawable(null); fadeOut.setBackground(null); } // only one photo in memory
                    fadeIn = null;
                    fadeOut = null;
                } else {
                    more = true;
                }
            }
            if (zoom && zoomView != null) {
                float t = Math.min(1f, (now - zoomStart) / (float) zoomMs);
                float sc = 1f + 0.08f * t;
                zoomView.setScaleX(sc);
                zoomView.setScaleY(sc);
                if (t < 1f) more = true;
            }
            if (more) handler.postDelayed(this, 16);
        }
    };

    /** Decodes the next photo off the UI thread, then cross-fades to it. */
    private void showNext() {
        if (photos.isEmpty()) return;
        final File f = photos.get(index % photos.size());
        index++;
        io.execute(() -> {
            final Bitmap b = Photos.load(ctx, f);
            if (b != null) b.prepareToDraw(); // upload ahead, so the fade does not stutter
            // A photo far from the screen's shape (a portrait shot on a wide TV) is shown whole,
            // on a blurred, darkened copy of itself — cropping it would cut off half the picture.
            Bitmap back = null;
            if (b != null) {
                float sw = ctx.getResources().getDisplayMetrics().widthPixels;
                float sh = Math.max(1, ctx.getResources().getDisplayMetrics().heightPixels);
                float r = b.getWidth() / (float) Math.max(1, b.getHeight()), rs = sw / sh;
                if (r < rs * 0.7f || r > rs * 1.4f) {
                    back = Bitmap.createScaledBitmap(b, 24, Math.max(1, Math.round(24 / rs)), true);
                }
            }
            final Bitmap blur = back;
            handler.post(() -> {
                if (b == null || views == null) return;
                ImageView in = views[1 - front], out = views[front];
                front = 1 - front;
                if (fadeOut != null) { fadeOut.setImageDrawable(null); fadeOut.setBackground(null); } // a fade still running: drop it
                if (blur != null) {
                    android.graphics.drawable.BitmapDrawable d = new android.graphics.drawable.BitmapDrawable(ctx.getResources(), blur);
                    d.setFilterBitmap(true);
                    d.setColorFilter(0xFF6E6E6E, android.graphics.PorterDuff.Mode.MULTIPLY);
                    in.setBackground(d);
                    in.setScaleType(ImageView.ScaleType.FIT_CENTER);
                } else {
                    in.setBackground(null);
                    in.setScaleType(ImageView.ScaleType.CENTER_CROP);
                }
                in.setImageBitmap(b);
                in.setAlpha(0f);
                in.setScaleX(1f);
                in.setScaleY(1f);
                in.bringToFront();
                fadeIn = in;
                fadeOut = out.getDrawable() == null ? null : out;
                fadeStart = android.os.SystemClock.uptimeMillis();
                zoom = prefs.anim() != Prefs.ANIM_OFF;
                zoomView = in;
                zoomStart = fadeStart;
                zoomMs = prefs.photoSec() * 1000L + FADE_MS;
                if (shade != null) shade.bringToFront();
                if (info != null) info.bringToFront();
                handler.removeCallbacks(tick);
                handler.post(tick);
            });
        });
    }

    void stop() {
        started = false;
        handler.removeCallbacksAndMessages(null);
        stopMusic();
    }

    void destroy() {
        stop();
        io.shutdownNow();
        views = null;
    }
}
