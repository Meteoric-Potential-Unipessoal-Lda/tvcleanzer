package com.tvcleanzer.launcher;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Point;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Virtual mouse (0.77, asked in the chat for browsers and apps made for phones): a pointer
 * drawn over everything by the Home-key service, moved from the phone's pad; a tap is a touch
 * at the pointer (Android 7+: accessibility gestures). The phone reaches us over its ADB
 * connection («tcp:» stream to the TV's own loopback), one line per command:
 *   m dx dy — move (units of a 1920-wide screen); c — tap; l — long press;
 *   s dx dy — scroll (drag the page by dx, dy); q — done.
 * Nothing listens until the phone asks (ConfigReceiver «mouse»); only the TV itself can connect.
 */
final class Mouse {
    static final int PORT = 47291;

    private final AccessibilityService svc;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile ServerSocket server;
    private View cursor;
    private WindowManager.LayoutParams lp;
    private float x = -1, y = -1;
    private int sw, sh;
    private final Runnable hide = () -> show(false);

    Mouse(AccessibilityService s) { svc = s; }

    synchronized boolean start() {
        if (android.os.Build.VERSION.SDK_INT < 24) return false;
        if (server != null) return true;
        try {
            server = new ServerSocket(PORT, 1, InetAddress.getByName("127.0.0.1"));
        } catch (Throwable t) {
            HomeKeyService.log("mouse: " + t);
            return false;
        }
        Thread th = new Thread(this::serve, "tvc-mouse");
        th.setDaemon(true);
        th.start();
        HomeKeyService.log("mouse: listening");
        return true;
    }

    synchronized void stop() {
        ServerSocket s = server;
        server = null;
        try { if (s != null) s.close(); } catch (Throwable ignored) {}
        main.post(this::remove);
    }

    private void serve() {
        while (true) {
            ServerSocket ss = server;
            if (ss == null) return;
            try (Socket s = ss.accept()) {
                s.setTcpNoDelay(true);
                BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                main.post(() -> show(true));
                String line;
                while ((line = r.readLine()) != null) {
                    if (line.startsWith("q")) break;
                    handle(line.trim());
                }
            } catch (Throwable t) {
                if (server == null) return;
            }
            main.post(() -> show(false));
        }
    }

    private void handle(String l) {
        if (l.isEmpty()) return;
        String[] p = l.split(" ");
        try {
            switch (l.charAt(0)) {
                case 'm': {
                    final float dx = Float.parseFloat(p[1]), dy = Float.parseFloat(p[2]);
                    main.post(() -> moveBy(dx, dy));
                    break;
                }
                case 'c': main.post(() -> touch(0, 0, 60)); break;
                case 'l': main.post(() -> touch(0, 0, 700)); break;
                case 's': {
                    final float dx = Float.parseFloat(p[1]), dy = Float.parseFloat(p[2]);
                    main.post(() -> touch(dx, dy, 260));
                    break;
                }
                default: break;
            }
        } catch (Throwable ignored) {}
    }

    private void size() {
        Point pt = new Point();
        ((WindowManager) svc.getSystemService(Context.WINDOW_SERVICE)).getDefaultDisplay().getRealSize(pt);
        sw = pt.x;
        sh = pt.y;
        if (x < 0) { x = sw / 2f; y = sh / 2f; }
    }

    private void show(boolean on) {
        main.removeCallbacks(hide);
        if (!on) {
            if (cursor != null) cursor.setVisibility(View.GONE);
            return;
        }
        size();
        if (cursor == null) {
            cursor = new Pointer(svc);
            int s = Math.round(svc.getResources().getDisplayMetrics().density * 30);
            lp = new WindowManager.LayoutParams(s, s,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.x = Math.round(x);
            lp.y = Math.round(y);
            try {
                ((WindowManager) svc.getSystemService(Context.WINDOW_SERVICE)).addView(cursor, lp);
            } catch (Throwable t) {
                HomeKeyService.log("mouse: " + t);
                cursor = null;
                return;
            }
        }
        cursor.setVisibility(View.VISIBLE);
        main.postDelayed(hide, 8000); // still: hide the pointer, it comes back with the next move
    }

    private void moveBy(float dx, float dy) {
        if (sw == 0) size();
        float k = sw / 1920f;
        x = Math.max(0, Math.min(sw - 1, x + dx * k));
        y = Math.max(0, Math.min(sh - 1, y + dy * k));
        show(true);
        if (cursor != null && lp != null) {
            lp.x = Math.round(x);
            lp.y = Math.round(y);
            try {
                ((WindowManager) svc.getSystemService(Context.WINDOW_SERVICE)).updateViewLayout(cursor, lp);
            } catch (Throwable ignored) {}
        }
    }

    /** A touch at the pointer: a tap, a long press, or a drag by (dx, dy) to scroll. */
    private void touch(float dx, float dy, long ms) {
        if (android.os.Build.VERSION.SDK_INT < 24) return;
        if (sw == 0) size();
        show(true);
        float k = sw / 1920f;
        Path path = new Path();
        path.moveTo(x, y);
        if (dx != 0 || dy != 0) {
            float ex = Math.max(1, Math.min(sw - 2, x + dx * k)), ey = Math.max(1, Math.min(sh - 2, y + dy * k));
            path.lineTo(ex, ey);
        }
        try {
            GestureDescription g = new GestureDescription.Builder()
                    .addStroke(new GestureDescription.StrokeDescription(path, 0, ms))
                    .build();
            svc.dispatchGesture(g, null, null);
        } catch (Throwable t) {
            HomeKeyService.log("mouse: " + t);
        }
    }

    private void remove() {
        main.removeCallbacks(hide);
        if (cursor != null) {
            try { ((WindowManager) svc.getSystemService(Context.WINDOW_SERVICE)).removeView(cursor); } catch (Throwable ignored) {}
            cursor = null;
        }
    }

    /** A classic arrow pointer: white with a dark edge, its tip at the view's top-left. */
    private static final class Pointer extends View {
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG), edge = new Paint(Paint.ANTI_ALIAS_FLAG);
        Pointer(Context c) {
            super(c);
            fill.setColor(0xFFFFFFFF);
            edge.setColor(0xE6000000);
            edge.setStyle(Paint.Style.STROKE);
            edge.setStrokeJoin(Paint.Join.ROUND);
        }
        @Override protected void onDraw(Canvas c) {
            float s = getWidth() / 30f;
            edge.setStrokeWidth(1.8f * s);
            Path p = new Path();
            p.moveTo(2 * s, 2 * s);
            p.lineTo(2 * s, 24 * s);
            p.lineTo(8 * s, 18.5f * s);
            p.lineTo(12 * s, 27 * s);
            p.lineTo(16 * s, 25.2f * s);
            p.lineTo(12 * s, 17 * s);
            p.lineTo(19.5f * s, 17 * s);
            p.close();
            c.drawPath(p, fill);
            c.drawPath(p, edge);
        }
    }
}
