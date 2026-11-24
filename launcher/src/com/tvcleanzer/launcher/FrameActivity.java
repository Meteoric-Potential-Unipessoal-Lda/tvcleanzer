package com.tvcleanzer.launcher;

import android.app.Activity;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

/**
 * «Показать сейчас» (1.24): the photo frame as a screen of its own, started by the phone over
 * ADB. Xiaomi MiTV-AFKR0 (Android 14) refused SystemUI's «start the screensaver now», so the
 * button did nothing. Like the screensaver, any button on the remote closes it (and does nothing
 * else).
 */
public class FrameActivity extends Activity {
    private PhotoFrame frame;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        frame = new PhotoFrame(this);
        setContentView(frame.build());
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (frame != null) frame.start();
    }

    @Override
    protected void onStop() {
        // left (Home, another app, the TV's own screensaver): gone, not waiting in the back
        if (frame != null) frame.stop();
        super.onStop();
        finish();
    }

    @Override
    protected void onDestroy() {
        if (frame != null) frame.destroy();
        frame = null;
        super.onDestroy();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        // the volume keys still change the volume of the frame's music
        int k = e.getKeyCode();
        if (k == KeyEvent.KEYCODE_VOLUME_UP || k == KeyEvent.KEYCODE_VOLUME_DOWN || k == KeyEvent.KEYCODE_VOLUME_MUTE) {
            return super.dispatchKeyEvent(e);
        }
        if (e.getAction() == KeyEvent.ACTION_UP) finish();
        return true;
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent e) {
        if (e.getAction() == MotionEvent.ACTION_UP) finish();
        return true;
    }
}
