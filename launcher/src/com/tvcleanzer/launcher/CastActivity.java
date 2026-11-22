package com.tvcleanzer.launcher;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.VideoView;

import java.io.File;

/**
 * A photo or a video sent from the phone («Трансляция» on the phone's remote). The phone
 * streams the file into the launcher (StateProvider "cast") and starts this screen; while the
 * file is still on its way the phone opens it with type "wait" (0.61+), so the TV shows that
 * something is coming instead of nothing.
 * Video: OK pauses, ◀ ▶ jump 10 s, ▲ ▼ a minute; a bar with the time shows on every press
 * and while paused. Back closes, deletes the file and goes to this home screen.
 */
public class CastActivity extends Activity {
    static File file(Context c) {
        File d = new File(c.getFilesDir(), "cast");
        if (!d.isDirectory()) d.mkdirs();
        return new File(d, "cast.bin");
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private VideoView video;
    private LinearLayout bar;
    private ProgressBar progress;
    private TextView time, state;
    private View loading;

    private final Runnable hideBar = () -> {
        if (bar != null && video != null && video.isPlaying()) bar.animate().alpha(0f).setDuration(400).start();
    };
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            updateBar();
            handler.postDelayed(this, 500);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);
        setContentView(root);
        String type = getIntent().getStringExtra("type");
        if ("close".equals(type)) { close(); return; } // the upload failed: no waiting screen left behind
        if ("wait".equals(type)) {
            root.addView(waiting(T.t("Видео загружается с телефона…")), new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
            return;
        }
        File f = file(this);
        if (!f.isFile()) { close(); return; }
        if ("video".equals(type)) {
            video = new VideoView(this);
            video.setVideoPath(f.getPath());
            video.setOnPreparedListener(mp -> {
                if (loading != null) loading.setVisibility(View.GONE);
                video.start();
                showBar();
            });
            video.setOnCompletionListener(mp -> close());
            video.setOnErrorListener((mp, what, extra) -> {
                android.widget.Toast.makeText(this, T.t("Телевизор не умеет показывать это видео"),
                        android.widget.Toast.LENGTH_LONG).show();
                close();
                return true;
            });
            root.addView(video, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
            loading = waiting(T.t("Открываем видео…"));
            root.addView(loading, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
            root.addView(controls(), new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));
            handler.post(tick);
        } else {
            ImageView iv = new ImageView(this);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setImageBitmap(decode(f));
            root.addView(iv, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        }
    }

    private View waiting(String text) {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setGravity(Gravity.CENTER_HORIZONTAL);
        ProgressBar spin = new ProgressBar(this);
        l.addView(spin, new LinearLayout.LayoutParams(Ui.dp(this, 56), Ui.dp(this, 56)));
        TextView t = Ui.text(this, 20, 0xE6FFFFFF, "sans-serif-medium");
        t.setText(text);
        LinearLayout.LayoutParams tl = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        tl.topMargin = Ui.dp(this, 18);
        l.addView(t, tl);
        return l;
    }

    /** The bar at the bottom: ▶/⏸, the position, the length and what the keys do. */
    private View controls() {
        bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.VERTICAL);
        int ph = Ui.dp(this, 48), pv = Ui.dp(this, 26);
        bar.setPadding(ph, pv, ph, pv);
        bar.setBackground(new android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.BOTTOM_TOP, new int[]{0xCC000000, 0x00000000}));
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        state = Ui.text(this, 22, 0xFFFFFFFF, "sans-serif-medium");
        row.addView(state);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(1000);
        LinearLayout.LayoutParams pl = new LinearLayout.LayoutParams(0, Ui.dp(this, 8), 1f);
        pl.leftMargin = Ui.dp(this, 18);
        pl.rightMargin = Ui.dp(this, 18);
        row.addView(progress, pl);
        time = Ui.text(this, 18, 0xE6FFFFFF, "sans-serif-medium");
        row.addView(time);
        bar.addView(row);
        TextView hint = Ui.text(this, 15, 0x99FFFFFF, "sans-serif");
        hint.setText(T.t("ОК — пауза · ◀ ▶ — 10 секунд · ▲ ▼ — минута · «Назад» — закрыть"));
        LinearLayout.LayoutParams hl = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        hl.topMargin = Ui.dp(this, 10);
        bar.addView(hint, hl);
        return bar;
    }

    private static String clock(int ms) {
        int s = Math.max(0, ms / 1000), h = s / 3600, m = s / 60 % 60;
        return h > 0 ? String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s % 60)
                : String.format(java.util.Locale.US, "%d:%02d", m, s % 60);
    }

    private void updateBar() {
        if (video == null || bar == null) return;
        int d = video.getDuration(), p = video.getCurrentPosition();
        progress.setProgress(d > 0 ? (int) (1000L * p / d) : 0);
        time.setText(clock(p) + " / " + (d > 0 ? clock(d) : "–"));
        state.setText(video.isPlaying() ? "⏸" : "▶");
    }

    private void showBar() {
        if (bar == null) return;
        updateBar();
        bar.animate().cancel();
        bar.setAlpha(1f);
        handler.removeCallbacks(hideBar);
        handler.postDelayed(hideBar, 3500);
    }

    /** Back, the end of the film or an error: our home screen when it is the TV's home, not
     *  whatever app was under this screen (owners landed in the firmware's home). */
    private void close() {
        try {
            Prefs p = new Prefs(this);
            Intent h = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
            android.content.pm.ResolveInfo ri = getPackageManager().resolveActivity(h, 0);
            boolean ours = HomeKeyService.running != null || p.stockOff()
                    || (ri != null && ri.activityInfo != null && getPackageName().equals(ri.activityInfo.packageName));
            if (ours) {
                startActivity(new Intent(this, HomeActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP));
            }
        } catch (Throwable ignored) {}
        finish();
    }

    /** Big photos sampled down to the screen: a 48-megapixel picture would not fit in memory. */
    private Bitmap decode(File f) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(f.getPath(), o);
        int w = getResources().getDisplayMetrics().widthPixels, h = getResources().getDisplayMetrics().heightPixels;
        int s = 1;
        while (o.outWidth / (s * 2) >= w && o.outHeight / (s * 2) >= h) s *= 2;
        o = new BitmapFactory.Options();
        o.inSampleSize = s;
        return BitmapFactory.decodeFile(f.getPath(), o);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        recreate(); // a new photo / video from the phone (or the one that was on its way)
    }

    @Override
    public void onBackPressed() {
        close();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (video != null) video.stopPlayback();
        // a film of several gigabytes must not stay on the TV after watching
        String t = getIntent().getStringExtra("type");
        if (isFinishing() && !"wait".equals(t) && !"close".equals(t)) file(this).delete();
        super.onDestroy();
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (video != null) {
            switch (code) {
                case KeyEvent.KEYCODE_DPAD_CENTER: case KeyEvent.KEYCODE_ENTER:
                case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE: case KeyEvent.KEYCODE_MEDIA_PLAY: case KeyEvent.KEYCODE_MEDIA_PAUSE:
                    if (video.isPlaying()) video.pause(); else video.start();
                    showBar();
                    if (!video.isPlaying()) handler.removeCallbacks(hideBar); // paused: the bar stays
                    return true;
                case KeyEvent.KEYCODE_DPAD_LEFT: case KeyEvent.KEYCODE_MEDIA_REWIND:
                    video.seekTo(Math.max(0, video.getCurrentPosition() - 10000));
                    showBar();
                    return true;
                case KeyEvent.KEYCODE_DPAD_RIGHT: case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
                    video.seekTo(Math.min(video.getDuration(), video.getCurrentPosition() + 10000));
                    showBar();
                    return true;
                case KeyEvent.KEYCODE_DPAD_UP: // a film: a minute at a time
                    video.seekTo(Math.min(video.getDuration(), video.getCurrentPosition() + 60000));
                    showBar();
                    return true;
                case KeyEvent.KEYCODE_DPAD_DOWN:
                    video.seekTo(Math.max(0, video.getCurrentPosition() - 60000));
                    showBar();
                    return true;
                default:
            }
        }
        return super.onKeyDown(code, e);
    }
}
