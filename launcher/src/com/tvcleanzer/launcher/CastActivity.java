package com.tvcleanzer.launcher;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.VideoView;

import java.io.File;

/**
 * A photo or a video sent from the phone («Трансляция» on the phone's remote). The phone
 * streams the file into the launcher (StateProvider "cast") and starts this screen.
 * Video: OK pauses, ◀ ▶ jump 10 s; Back closes.
 */
public class CastActivity extends Activity {
    static File file(Context c) {
        File d = new File(c.getFilesDir(), "cast");
        if (!d.isDirectory()) d.mkdirs();
        return new File(d, "cast.bin");
    }

    private VideoView video;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);
        setContentView(root);
        File f = file(this);
        String type = getIntent().getStringExtra("type");
        if (!f.isFile()) { finish(); return; }
        if ("video".equals(type)) {
            video = new VideoView(this);
            video.setVideoPath(f.getPath());
            video.setOnPreparedListener(mp -> video.start());
            video.setOnCompletionListener(mp -> finish());
            video.setOnErrorListener((mp, what, extra) -> {
                android.widget.Toast.makeText(this, T.t("Телевизор не умеет показывать это видео"),
                        android.widget.Toast.LENGTH_LONG).show();
                finish();
                return true;
            });
            root.addView(video, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        } else {
            ImageView iv = new ImageView(this);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setImageBitmap(decode(f));
            root.addView(iv, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        }
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
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        recreate(); // a new photo / video from the phone
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (video != null) {
            switch (code) {
                case KeyEvent.KEYCODE_DPAD_CENTER: case KeyEvent.KEYCODE_ENTER:
                case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                    if (video.isPlaying()) video.pause(); else video.start();
                    return true;
                case KeyEvent.KEYCODE_DPAD_LEFT: case KeyEvent.KEYCODE_MEDIA_REWIND:
                    video.seekTo(Math.max(0, video.getCurrentPosition() - 10000));
                    return true;
                case KeyEvent.KEYCODE_DPAD_RIGHT: case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
                    video.seekTo(Math.min(video.getDuration(), video.getCurrentPosition() + 10000));
                    return true;
                default:
            }
        }
        return super.onKeyDown(code, e);
    }
}
