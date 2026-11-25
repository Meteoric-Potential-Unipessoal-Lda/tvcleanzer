package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.media.MediaPlayer;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.TextureView;
import android.widget.FrameLayout;

import java.io.File;

/**
 * «Живые обои» (0.61+): a short video from the phone, looping without sound behind the home
 * screen, cropped to fill it. The player lets go of the video decoder whenever the home screen
 * is not on screen: many TVs have only one, and YouTube would get none.
 *   content write --uri content://com.tvcleanzer.launcher.state/wallvideo < clip.mp4
 *
 * 1.48: two ways to draw. A TextureView first (drawn with the rest of the screen); on TVs whose
 * decoder gives it no picture (a Hyundai on Android 7: the clip was there, the player «didn't
 * catch it», opened by hand it played) a SurfaceView, the video plane behind the window — kept
 * for this TV from then on.
 */
final class LiveWall extends FrameLayout {
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

    private static final String PREFS = "live_wall";

    /** This TV draws the video only through a SurfaceView (learnt once). */
    static boolean surfaceMode(Context c) {
        try { return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("surface", false); } catch (Throwable t) { return false; }
    }

    /** 0.86: told when the video can't play here (TCL: the photo stayed hidden behind a video
     *  that never started — the owner saw only the theme), so the photo is shown instead. */
    interface Listener { void failed(String why); }
    Listener listener;

    /** 1.48: the TextureView gave no picture: build the home again (a SurfaceView this time). */
    Runnable retry;

    private final boolean useSurface;
    private TextureView texture;
    private SurfaceView sv;
    private MediaPlayer player;
    private Surface surface;
    private final Runnable stuck = () -> fail("not ready in 10 s");
    private boolean prepared, wanted;
    private int videoW, videoH;

    LiveWall(Context c) {
        super(c);
        setFocusable(false);
        useSurface = surfaceMode(c);
        if (useSurface) {
            sv = new SurfaceView(c);
            sv.setFocusable(false);
            sv.getHolder().addCallback(new SurfaceHolder.Callback() {
                @Override public void surfaceCreated(SurfaceHolder h) {
                    surface = h.getSurface();
                    if (wanted) open();
                }
                @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}
                @Override public void surfaceDestroyed(SurfaceHolder h) {
                    release();
                    surface = null;
                }
            });
            addView(sv, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER));
            HomeKeyService.log("live wallpaper: drawn through SurfaceView");
        } else {
            texture = new TextureView(c);
            texture.setFocusable(false);
            // 0.87: until a frame arrives the theme shows through, not black (TextureView is opaque
            // by default: a Hyundai on Android 7 stayed black with a video it never drew)
            texture.setOpaque(false);
            texture.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
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
                @Override public void onSurfaceTextureUpdated(SurfaceTexture st) {
                    if (!gotFrame) {
                        gotFrame = true;
                        removeCallbacks(noPicture);
                    }
                }
            });
            addView(texture, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        }
    }

    private boolean gotFrame;
    private final Runnable noPicture = () -> {
        if (!gotFrame && this.player != null && this.prepared) fail("no picture in 8 s");
    };

    /** The home screen is in front: play (opens the file again if it was let go). */
    void play() {
        wanted = true;
        if (player == null) open();
        else if (prepared) {
            volume(player);
            if (!player.isPlaying()) player.start();
        }
    }

    /** Silent unless the owner turned the sound on (1.05); quieter than the clip itself. */
    private void volume(MediaPlayer m) {
        float v = new Prefs(getContext()).liveSound() ? 0.7f : 0f;
        try { m.setVolume(v, v); } catch (Exception ignored) {}
    }

    /** The home screen is covered: give the decoder back. */
    void stop() {
        wanted = false;
        removeCallbacks(stuck);
        removeCallbacks(noPicture);
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
            if (useSurface) m.setDisplay(sv.getHolder());
            else m.setSurface(surface);
            m.setLooping(true);
            volume(m);
            m.setOnPreparedListener(mp -> {
                if (player != mp) return;
                removeCallbacks(stuck);
                prepared = true;
                videoW = mp.getVideoWidth();
                videoH = mp.getVideoHeight();
                HomeKeyService.log("live wallpaper: playing " + videoW + "x" + videoH + (useSurface ? " (surface)" : ""));
                fit();
                if (wanted) {
                    mp.start();
                    gotFrame = false;
                    removeCallbacks(noPicture);
                    // a SurfaceView can't tell whether it drew: no check there
                    if (!useSurface) postDelayed(noPicture, 8000);
                }
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
        removeCallbacks(noPicture);
        if (!useSurface && why.startsWith("no picture") && retry != null) {
            HomeKeyService.log("live wallpaper: no picture through TextureView, trying SurfaceView");
            try { getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("surface", true).commit(); } catch (Throwable ignored) {}
            release();
            retry.run();
            return;
        }
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

    @Override protected void onSizeChanged(int w, int h, int ow, int oh) {
        super.onSizeChanged(w, h, ow, oh);
        post(this::fit);
    }

    /** Centre crop: the video fills the screen whatever its shape. */
    private void fit() {
        int w = getWidth(), h = getHeight();
        if (w == 0 || h == 0 || videoW == 0 || videoH == 0) return;
        float scale = Math.max((float) w / videoW, (float) h / videoH);
        if (useSurface) {
            // the surface a little larger than the screen, centred: the sides fall outside
            int cw = Math.round(videoW * scale), ch = Math.round(videoH * scale);
            LayoutParams lp = (LayoutParams) sv.getLayoutParams();
            if (lp.width != cw || lp.height != ch) {
                lp.width = cw;
                lp.height = ch;
                lp.gravity = Gravity.CENTER;
                sv.setLayoutParams(lp);
            }
            return;
        }
        Matrix m = new Matrix();
        m.setScale(videoW * scale / w, videoH * scale / h, w / 2f, h / 2f);
        texture.setTransform(m);
    }
}
