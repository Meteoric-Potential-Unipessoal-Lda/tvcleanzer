package com.tvcleanzer.launcher;

import android.app.Activity;
import android.content.Intent;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.concurrent.ArrayBlockingQueue;

/**
 * «Повтор экрана»: the phone's screen (and sound) on the TV. The phone app starts this screen
 * over ADB with a one-time token, then connects to the TV's port and streams H.264 video plus
 * raw PCM sound; we decode straight onto a SurfaceView.
 *
 * Stream (big-endian): int magic "TVCM", int version, UTF token; the TV answers one byte
 * (1 = accepted). Then packets: byte type, int length, long pts (µs), payload.
 *   1 video config: int width, int height, SPS+PPS   2 frame   3 key frame
 *   4 sound config: int sample rate, int channels     5 PCM 16-bit   9 bye
 * Back on the remote, or the phone stopping, closes the screen.
 */
public class MirrorActivity extends Activity implements SurfaceHolder.Callback {
    static final int MAGIC = 0x5456434D, PORT = 7300;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Object surfaceLock = new Object();
    private FrameLayout root;
    private SurfaceView view;
    private TextView hint;
    private Surface surface;
    private volatile String token;
    private volatile ServerSocket server;
    private volatile Socket sock;
    private volatile boolean closed;
    private volatile MediaCodec codec;
    private int vw, vh;
    private volatile Sound sound;
    private final Runnable idle = this::finish;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        root = new FrameLayout(this);
        root.setBackgroundColor(0xFF000000);
        view = new SurfaceView(this);
        view.getHolder().addCallback(this);
        root.addView(view, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        hint = new TextView(this);
        hint.setText(T.t("Ждём телефон…"));
        hint.setTextColor(0x99FFFFFF);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        root.addView(hint, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        setContentView(root);
        take(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        take(intent);
    }

    /** A new session from the phone: its token, the listening port; «close» ends the screen. */
    private void take(Intent i) {
        if (i.getBooleanExtra("close", false)) { finish(); return; }
        token = i.getStringExtra("token");
        if (token == null || token.isEmpty()) { finish(); return; }
        int port = i.getIntExtra("port", PORT);
        Socket old = sock; // the phone starts over
        sock = null;
        closeQuietly(old);
        if (server == null || server.getLocalPort() != port) {
            closeQuietly(server);
            try {
                ServerSocket s = new ServerSocket();
                s.setReuseAddress(true);
                s.bind(new InetSocketAddress(port));
                server = s;
            } catch (IOException e) {
                finish();
                return;
            }
            final ServerSocket s = server;
            new Thread(() -> acceptLoop(s), "mirror-accept").start();
        }
        hint.setVisibility(View.VISIBLE);
        ui.removeCallbacks(idle);
        ui.postDelayed(idle, 60_000); // nobody came
    }

    private void acceptLoop(ServerSocket s) {
        while (!closed && server == s) {
            try {
                Socket c = s.accept();
                Socket old = sock;
                sock = c;
                closeQuietly(old);
                new Thread(() -> serve(c), "mirror-read").start();
            } catch (IOException e) {
                return; // closed
            }
        }
    }

    private void serve(Socket s) {
        try {
            s.setTcpNoDelay(true);
            s.setReceiveBufferSize(1 << 20);
            DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 1 << 16));
            OutputStream out = s.getOutputStream();
            s.setSoTimeout(10_000);
            if (in.readInt() != MAGIC) { s.close(); return; }
            in.readInt(); // version
            String t = in.readUTF();
            if (!t.equals(token)) { out.write(0); out.flush(); s.close(); return; }
            out.write(1);
            out.flush();
            s.setSoTimeout(0);
            ui.post(() -> { ui.removeCallbacks(idle); hint.setVisibility(View.GONE); });
            byte[] buf = new byte[1 << 20];
            while (!closed) {
                int type = in.readUnsignedByte();
                int len = in.readInt();
                long pts = in.readLong();
                if (len < 0 || len > (32 << 20)) throw new IOException("bad packet");
                if (buf.length < len) buf = new byte[len];
                in.readFully(buf, 0, len);
                switch (type) {
                    case 1: video(ByteBuffer.wrap(buf, 0, 8).getInt(), ByteBuffer.wrap(buf, 4, 4).getInt(), buf, 8, len - 8); break;
                    case 2: case 3: frame(buf, len, pts); break;
                    case 4: soundConfig(ByteBuffer.wrap(buf, 0, 8).getInt(), ByteBuffer.wrap(buf, 4, 4).getInt()); break;
                    case 5: Sound sd = sound; if (sd != null) sd.play(buf, len); break;
                    case 9: throw new IOException("bye");
                    default: break;
                }
            }
        } catch (Exception e) {
            // the phone stopped or the Wi-Fi dropped
        } finally {
            closeQuietly(s);
            if (sock == s) ui.post(this::finish);
        }
    }

    /** A new picture size (start, or the phone turned): a fresh decoder for it. */
    private void video(int w, int h, byte[] csd, int off, int len) throws IOException, InterruptedException {
        stopCodec();
        Surface out;
        synchronized (surfaceLock) {
            long until = System.currentTimeMillis() + 5000;
            while (surface == null && System.currentTimeMillis() < until) surfaceLock.wait(200);
            out = surface;
        }
        if (out == null) throw new IOException("no surface");
        vw = w;
        vh = h;
        ui.post(this::fit);
        MediaCodec c = MediaCodec.createDecoderByType("video/avc");
        MediaFormat f = MediaFormat.createVideoFormat("video/avc", w, h);
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Math.max(w * h, 1 << 20));
        f.setInteger("low-latency", 1); // Android 11+; ignored elsewhere
        f.setInteger("vendor.low-latency.enable", 1); // MediaTek / Amlogic TV decoders
        try {
            c.configure(f, out, null, 0);
        } catch (Exception e) { // a firmware that refuses the vendor keys
            c.release();
            c = MediaCodec.createDecoderByType("video/avc");
            f = MediaFormat.createVideoFormat("video/avc", w, h);
            f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Math.max(w * h, 1 << 20));
            c.configure(f, out, null, 0);
        }
        c.start();
        codec = c;
        final MediaCodec dc = c;
        new Thread(() -> drain(dc), "mirror-decode").start();
        queue(c, csd, off, len, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
    }

    private void frame(byte[] b, int len, long pts) {
        MediaCodec c = codec;
        if (c != null) queue(c, b, 0, len, pts, 0);
    }

    private void queue(MediaCodec c, byte[] b, int off, int len, long pts, int flags) {
        try {
            int idx = -1;
            for (int i = 0; i < 20 && idx < 0 && !closed; i++) idx = c.dequeueInputBuffer(25_000);
            if (idx < 0) return; // the decoder is stuck: skip, the next key frame heals it
            ByteBuffer ib = c.getInputBuffer(idx);
            if (ib == null) return;
            ib.clear();
            if (ib.capacity() < len) { c.queueInputBuffer(idx, 0, 0, pts, 0); return; }
            ib.put(b, off, len);
            c.queueInputBuffer(idx, 0, len, pts, flags);
        } catch (IllegalStateException e) {
            // decoder replaced meanwhile
        }
    }

    private void drain(MediaCodec c) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            while (!closed && codec == c) {
                int idx = c.dequeueOutputBuffer(info, 20_000);
                if (idx >= 0) c.releaseOutputBuffer(idx, true); // show at once: no clock, least delay
            }
        } catch (IllegalStateException e) {
            // released
        }
    }

    private void stopCodec() {
        MediaCodec c = codec;
        codec = null;
        if (c == null) return;
        try { c.stop(); } catch (Exception ignored) { }
        try { c.release(); } catch (Exception ignored) { }
    }

    /** The picture keeps the phone's shape, centred on black. */
    private void fit() {
        if (vw <= 0 || vh <= 0) return;
        int pw = root.getWidth(), ph = root.getHeight();
        if (pw <= 0 || ph <= 0) {
            pw = getResources().getDisplayMetrics().widthPixels;
            ph = getResources().getDisplayMetrics().heightPixels;
        }
        int w = pw, h = (int) ((long) pw * vh / vw);
        if (h > ph) { h = ph; w = (int) ((long) ph * vw / vh); }
        view.setLayoutParams(new FrameLayout.LayoutParams(w, h, Gravity.CENTER));
    }

    private void soundConfig(int rate, int channels) {
        Sound old = sound;
        sound = null;
        if (old != null) old.close();
        try {
            sound = new Sound(rate, channels);
        } catch (Exception e) {
            // no sound on this TV: the picture still goes
        }
    }

    /** PCM to the speakers on its own thread; a backlog is dropped so the sound stays live. */
    private static final class Sound implements Runnable {
        private final AudioTrack track;
        private final ArrayBlockingQueue<byte[]> q = new ArrayBlockingQueue<>(24);
        private volatile boolean done;

        Sound(int rate, int channels) {
            int mask = channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
            int min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
            track = new AudioTrack(AudioManager.STREAM_MUSIC, rate, mask, AudioFormat.ENCODING_PCM_16BIT,
                    Math.max(min * 2, rate * channels * 2 / 10), AudioTrack.MODE_STREAM);
            track.play();
            new Thread(this, "mirror-sound").start();
        }

        void play(byte[] b, int len) {
            byte[] copy = new byte[len];
            System.arraycopy(b, 0, copy, 0, len);
            if (!q.offer(copy)) { q.clear(); q.offer(copy); }
        }

        @Override
        public void run() {
            try {
                while (!done) {
                    byte[] b = q.take();
                    track.write(b, 0, b.length);
                }
            } catch (Exception ignored) {
            } finally {
                try { track.stop(); } catch (Exception ignored) { }
                track.release();
            }
        }

        void close() {
            done = true;
            q.offer(new byte[0]);
        }
    }

    @Override
    public void surfaceCreated(SurfaceHolder h) {
        synchronized (surfaceLock) {
            surface = h.getSurface();
            surfaceLock.notifyAll();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder h, int format, int width, int height) { }

    @Override
    public void surfaceDestroyed(SurfaceHolder h) {
        synchronized (surfaceLock) { surface = null; }
        stopCodec();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) { finish(); return true; }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (!isChangingConfigurations()) finish(); // Home on the remote: the phone stops too
    }

    @Override
    protected void onDestroy() {
        closed = true;
        ui.removeCallbacks(idle);
        closeQuietly(server);
        closeQuietly(sock);
        stopCodec();
        Sound s = sound;
        sound = null;
        if (s != null) s.close();
        super.onDestroy();
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) return;
        try { c.close(); } catch (IOException ignored) { }
    }
}
