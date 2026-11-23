package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.media.MediaPlayer;
import android.view.Surface;
import android.view.TextureView;

import java.io.File;

/**
 * «Живые обои» (0.61+): a short video from the phone, looping without sound behind the home
 * screen, cropped to fill it. The player lets go of the video decoder whenever the home screen
 * is not on screen: many TVs have only one, and YouTube would get none.
 *   content write --uri content://com.tvcleanzer.launcher.state/wallvideo < clip.mp4
 */
final class LiveWall extends TextureView implements TextureView.SurfaceTextureListener {
    /** Where the phone writes it: the app's own files (Android 10+, content write). */
    static File internal(Context c) { return new File(c.getFilesDir(), "wallvideo.mp4"); }

    /** Older Android: the phone copies it into the external files dir. */
    static File legacy(Context c) {
        File e = c.getExternalFilesDir(null);
        return e == null ? null : new File(e, "wallvideo.mp4");
    }

    static File file(Context c) {
        File a = internal(c), b = legacy(c);
        if (b != null && b.isFile() && (!a.isFile() || b.lastModified() > a.lastModified())) return b;
        return a;
    }

    static boolean exists(Context c) { File f = file(c); return f.isFile() && f.length() > 0; }

    static void delete(Context c) {
        //noinspection ResultOfMethodCallIgnored
        internal(c).delete();
        File b = legacy(c);
        //noinspection ResultOfMethodCallIgnored
        if (b != null) b.delete();
    }

    /** 0.86: told when the video can't play here (TCL: the photo stayed hidden behind a video
     *  that never started — the owner saw only the theme), so the photo is shown instead. */
    interface Listener { void failed(String why); }
    Listener listener;

    private MediaPlayer player;
    private Surface surface;
    private final Runnable stuck = () -> fail("not ready in 10 s");
    private boolean prepared, wanted;
    private int videoW, videoH;

    LiveWall(Context c) {
        super(c);
        setSurfaceTextureListener(this);
        setFocusable(false);
    }

    /** The home screen is in front: play (opens the file again if it was let go). */
    void play() {
        wanted = true;
        if (player == null) open();
        else if (prepared && !player.isPlaying()) player.start();
    }

    /** The home screen is covered: give the decoder back. */
    void stop() {
        wanted = false;
        removeCallbacks(stuck);
        release();
    }

    /** A new video came from the phone. */
    void reload() {
        release();
        if (wanted) open();
    }

    private void open() {
        if (surface == null || !exists(getContext())) return;
        release();
        MediaPlayer m = new MediaPlayer();
        try {
            m.setDataSource(file(getContext()).getPath());
            m.setSurface(surface);
            m.setLooping(true);
            m.setVolume(0f, 0f);
            m.setOnPreparedListener(mp -> {
                if (player != mp) return;
                removeCallbacks(stuck);
                prepared = true;
                videoW = mp.getVideoWidth();
                videoH = mp.getVideoHeight();
                HomeKeyService.log("live wallpaper: playing " + videoW + "x" + videoH);
                fit();
                if (wanted) mp.start();
            });
            m.setOnErrorListener((mp, what, extra) -> {
                if (player == mp) fail("error " + what + "/" + extra);
                return true;
            });
            player = m;
            m.prepareAsync();
            postDelayed(stuck, 10_000);
        } catch (Exception e) {
            m.release();
            player = null;
            fail(String.valueOf(e));
        }
    }

    private void fail(String why) {
        removeCallbacks(stuck);
        HomeKeyService.log("live wallpaper: can't play here (" + why + ")");
        release(); // the theme background stays visible behind
        if (listener != null) listener.failed(why);
    }

    private void release() {
        MediaPlayer m = player;
        player = null;
        prepared = false;
        if (m != null) {
            try { m.stop(); } catch (Exception ignored) {}
            m.release();
        }
    }

    /** Centre crop: the video fills the screen whatever its shape. */
    private void fit() {
        int w = getWidth(), h = getHeight();
        if (w == 0 || h == 0 || videoW == 0 || videoH == 0) return;
        float scale = Math.max((float) w / videoW, (float) h / videoH);
        Matrix m = new Matrix();
        m.setScale(videoW * scale / w, videoH * scale / h, w / 2f, h / 2f);
        setTransform(m);
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) {
        surface = new Surface(st);
        if (wanted) open();
    }

    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) { fit(); }

    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture st) {
        release();
        if (surface != null) surface.release();
        surface = null;
        return true;
    }

    @Override public void onSurfaceTextureUpdated(SurfaceTexture st) {}
}
