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
import android.view.accessibility.AccessibilityNodeInfo;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Virtual mouse (0.77, asked in the chat for browsers and apps made for phones): a pointer
 * drawn over everything, moved from the phone's pad. The phone reaches us over its ADB
 * connection («tcp:» stream to the TV's own loopback), one line per command:
 *   m dx dy — move (units of a 1920-wide screen); c — tap; l — long press;
 *   s dx dy — scroll (drag the page by dx, dy); q — done.
 * Two ways (0.79):
 *  · through the Home-key service: its own overlay, taps as accessibility gestures (Android 7+);
 *  · without it — a T95 / be311 box switches every third-party accessibility service off a
 *    second after it starts: an ordinary overlay window (the phone grants «draw over other
 *    apps» over ADB), and the touches go back to the phone as lines
 *      t x y · p x y (long) · w x1 y1 x2 y2 (drag)
 *    which it runs as `input tap / swipe` over ADB.
 * Nothing listens until the phone asks (ConfigReceiver «mouse»); only the TV itself can connect.
 */
final class Mouse {
    static final int PORT = 47291;

    /** The one without the service (application context). */
    private static Mouse plain;

    static Mouse plain(Context c) {
        if (plain == null) plain = new Mouse(c.getApplicationContext(), null);
        return plain;
    }

    /** May this app draw over others (granted over ADB: appops SYSTEM_ALERT_WINDOW)? */
    static boolean canOverlay(Context c) {
        if (android.os.Build.VERSION.SDK_INT < 23) return true;
        try { return android.provider.Settings.canDrawOverlays(c); } catch (Throwable t) { return false; }
    }

    private final Context ctx;
    private final AccessibilityService svc; // null: no gestures, touches go back to the phone
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile ServerSocket server;
    private volatile OutputStream client;
    private View cursor;
    private WindowManager.LayoutParams lp;
    private float x = -1, y = -1;
    private int sw, sh;
    private final Runnable hide = () -> show(false);

    Mouse(AccessibilityService s) { this(s, s); }

    private Mouse(Context c, AccessibilityService s) {
        ctx = c;
        svc = s;
    }

    synchronized boolean start() {
        if (svc != null && android.os.Build.VERSION.SDK_INT < 24) return false;
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
        HomeKeyService.log("mouse: listening (" + (svc != null ? "service" : "overlay") + ")");
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
                client = s.getOutputStream();
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
            client = null;
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

    private WindowManager wm() { return (WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE); }

    private void size() {
        Point pt = new Point();
        wm().getDefaultDisplay().getRealSize(pt);
        sw = pt.x;
        sh = pt.y;
        if (x < 0) { x = sw / 2f; y = sh / 2f; }
    }

    @SuppressWarnings("deprecation")
    private int overlayType() {
        if (svc != null) return WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY;
        return android.os.Build.VERSION.SDK_INT >= 26 ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
    }

    private void show(boolean on) {
        main.removeCallbacks(hide);
        if (!on) {
            // 0.84: the plain pointer only fades out. A window of ours on screen is what keeps the
            // launcher's process alive on a box with no service holding it (be311: «works for
            // 10 seconds» — the pointer hid after 8 s and the box killed the process)
            if (cursor != null) {
                if (svc == null) cursor.setAlpha(0f);
                else cursor.setVisibility(View.GONE);
            }
            return;
        }
        size();
        if (cursor == null) {
            cursor = new Pointer(ctx);
            int s = Math.round(ctx.getResources().getDisplayMetrics().density * 30);
            lp = new WindowManager.LayoutParams(s, s, overlayType(),
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.x = Math.round(x);
            lp.y = Math.round(y);
            try {
                wm().addView(cursor, lp);
            } catch (Throwable t) {
                HomeKeyService.log("mouse: " + t);
                cursor = null;
                return;
            }
        }
        cursor.setVisibility(View.VISIBLE);
        cursor.setAlpha(1f);
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
            try { wm().updateViewLayout(cursor, lp); } catch (Throwable ignored) {}
        }
    }

    /** A touch at the pointer: a tap, a long press, or a drag by (dx, dy) to scroll. */
    private void touch(float dx, float dy, long ms) {
        if (sw == 0) size();
        show(true);
        float k = sw / 1920f;
        float ex = x, ey = y;
        boolean drag = dx != 0 || dy != 0;
        if (drag) {
            ex = Math.max(1, Math.min(sw - 2, x + dx * k));
            ey = Math.max(1, Math.min(sh - 2, y + dy * k));
        }
        final String line = drag ? "w " + Math.round(x) + " " + Math.round(y) + " " + Math.round(ex) + " " + Math.round(ey)
                : (ms > 300 ? "p " : "t ") + Math.round(x) + " " + Math.round(y);
        if (svc == null || android.os.Build.VERSION.SDK_INT < 24) {
            // no gestures here: the phone touches the screen for us over ADB
            back(line);
            return;
        }
        // 1.03: a TV that drops our gestures (Haier, Android 11) — the phone's `input` over ADB
        // took a second a touch there, and touches piled up («через несколько секунд всё сразу»):
        // the app's own click / scroll under the pointer instead, the phone only where none is
        if (noGestures) {
            if (!nodeAction(drag, dx, dy, ms)) back(line);
            return;
        }
        final float fdx = dx, fdy = dy;
        Path path = new Path();
        path.moveTo(x, y);
        if (drag) path.lineTo(ex, ey);
        try {
            GestureDescription g = new GestureDescription.Builder()
                    .addStroke(new GestureDescription.StrokeDescription(path, 0, ms))
                    .build();
            // 1.02: a Haier (Android 11) — the pointer moved, a click opened nothing. A gesture the
            // system drops goes to the phone, which taps over ADB; the first few say how it went
            boolean ok = svc.dispatchGesture(g, new AccessibilityService.GestureResultCallback() {
                @Override public void onCompleted(GestureDescription d) { told("done"); }
                @Override public void onCancelled(GestureDescription d) {
                    noGestures = true;
                    told("cancelled");
                    if (!nodeAction(drag, fdx, fdy, ms)) back(line);
                }
            }, main);
            if (!ok) {
                noGestures = true;
                told("refused");
                if (!nodeAction(drag, fdx, fdy, ms)) back(line);
            }
        } catch (Throwable t) {
            HomeKeyService.log("mouse: " + t);
            back(line);
        }
    }

    private int toldTaps;
    /** The system drops our gestures here: no more waiting for them this session. */
    private boolean noGestures;
    private float scrollAcc;
    private long scrolledAt;

    /** Click, long click or scroll the app's own view under the pointer (accessibility). */
    private boolean nodeAction(boolean drag, float dx, float dy, long ms) {
        try {
            AccessibilityNodeInfo root = svc.getRootInActiveWindow();
            if (root == null) return false;
            int px = Math.round(x), py = Math.round(y);
            if (!drag) {
                boolean longPress = ms > 300;
                AccessibilityNodeInfo n = under(root, px, py, longPress ? 2 : 1);
                boolean ok = n != null && n.performAction(longPress
                        ? AccessibilityNodeInfo.ACTION_LONG_CLICK : AccessibilityNodeInfo.ACTION_CLICK);
                told(ok ? "by the app's view" : "no view here, the phone taps");
                return ok;
            }
            // a page at a time is a lot: only a real swipe scrolls, and not more than ~3 a second
            boolean vertical = Math.abs(dy) >= Math.abs(dx);
            scrollAcc += vertical ? dy : dx;
            long now = android.os.SystemClock.uptimeMillis();
            if (Math.abs(scrollAcc) < 220 || now - scrolledAt < 300) return true;
            boolean forward = scrollAcc < 0; // the finger goes up / left: on through the page
            scrollAcc = 0;
            scrolledAt = now;
            AccessibilityNodeInfo n = under(root, px, py, 3);
            return n != null && n.performAction(forward
                    ? AccessibilityNodeInfo.ACTION_SCROLL_FORWARD : AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD);
        } catch (Throwable t) {
            return false;
        }
    }

    /** The innermost view at (x, y) that can: 1 click, 2 long click, 3 scroll. */
    private static AccessibilityNodeInfo under(AccessibilityNodeInfo n, int x, int y, int what) {
        android.graphics.Rect r = new android.graphics.Rect();
        n.getBoundsInScreen(r);
        if (!r.contains(x, y)) return null;
        for (int i = n.getChildCount() - 1; i >= 0; i--) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c == null) continue;
            AccessibilityNodeInfo f = under(c, x, y, what);
            if (f != null) return f;
        }
        boolean can = what == 1 ? n.isClickable() : what == 2 ? n.isLongClickable() : n.isScrollable();
        return can && n.isVisibleToUser() ? n : null;
    }

    private void told(String how) {
        if (toldTaps++ < 3) HomeKeyService.log("mouse: tap " + how);
    }

    /** A touch the phone makes for us over ADB (`input tap / swipe`). */
    private void back(final String line) {
        new Thread(() -> {
            OutputStream o = client;
            if (o == null) return;
            try {
                synchronized (Mouse.this) { o.write((line + "\n").getBytes("UTF-8")); o.flush(); }
            } catch (Throwable ignored) {}
        }).start();
    }

    private void remove() {
        main.removeCallbacks(hide);
        if (cursor != null) {
            try { wm().removeView(cursor); } catch (Throwable ignored) {}
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
