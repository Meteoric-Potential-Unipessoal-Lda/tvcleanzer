package com.tvcleanzer.launcher;

import android.accessibilityservice.AccessibilityService;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Map;


/**
 * 1.40: the phone's remote over Wi-Fi, for a TV the phone can't reach over ADB (debugging
 * switched off again, a box that forgets the phone's key, no Google «Android TV Remote» service
 * on it). The phone pairs once with a code shown here, then sends keys, text, apps and the mouse.
 *
 * Wire (TCP [PORT], UTF-8 lines):
 *   TV:    TVC1 <tvNonce> <api> <name>
 *   phone: pair <id> <phoneNonce> <phoneKey> <name>     a new phone: the TV shows a 6-digit code
 *          TV:    code <tvKey>
 *          phone: code <proof>        (up to 3 tries) → TV: paired <tvProof> | bad <left> | fail
 *   phone: auth <id> <phoneNonce> <mac>                 a paired phone → TV: ok <mac> | who
 * The keys are P-256 (ECDH, raw points in base64); with Z the shared secret and T the transcript
 * tvNonce|phoneNonce|id|phoneKey|tvKey: P = SHA-256(Z ‖ code), proof = HMAC(P, "c|"T),
 * tvProof = HMAC(P, "s|"T), the phone's lasting key K = HMAC(P, "k|"T). auth's mac =
 * HMAC(K, "a|"tvNonce|phoneNonce|id); ok's = HMAC(K, "o|"tvNonce|phoneNonce). Someone listening
 * on the Wi-Fi learns nothing; the code proves both ends saw the same keys.
 * Then each phone line is «command #tag», tag = the first 8 bytes of
 * HMAC(HMAC(K, "sess|"tvNonce|phoneNonce), seq|command) with seq 1, 2, …: nothing can be slipped
 * in. Commands: k <key> · t <text> · a <package> · u <link> · v <level> · ? · p (ping) ·
 * the mouse's m / c / l / s / e (see Mouse). The TV answers st … (what works), pong, no <what>.
 */
final class LanRemote {
    static final int PORT = 47292;
    private static final int MAX_PHONES = 8, MAX_CLIENTS = 4;
    private static final long PAIR_MS = 120_000;

    private static volatile LanRemote inst;

    /** Starts listening where wanted; safe to call often. */
    static void ensure(Context c) {
        try {
            if (!new Prefs(c).lanRemote()) {
                stopAll();
                return;
            }
            synchronized (LanRemote.class) {
                if (inst == null) inst = new LanRemote(c.getApplicationContext());
            }
            inst.start();
        } catch (Throwable t) {
            HomeKeyService.log("lan: " + t);
        }
    }

    static void stopAll() {
        LanRemote r = inst;
        if (r != null) r.stop();
    }

    /** Forgets every paired phone (the TV's settings). */
    static void forgetAll(Context c) {
        c.getSharedPreferences("lan", Context.MODE_PRIVATE).edit().clear().commit();
        LanRemote r = inst;
        if (r != null) r.dropAll(); // the phones connected now go too
    }

    static int pairedCount(Context c) {
        int n = 0;
        for (String k : c.getSharedPreferences("lan", Context.MODE_PRIVATE).getAll().keySet()) {
            if (k.startsWith("k_")) n++;
        }
        return n;
    }

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final SecureRandom rnd = new SecureRandom();
    private volatile ServerSocket server;
    private int clients;
    private final java.util.Set<Socket> live = java.util.Collections.newSetFromMap(new java.util.concurrent.ConcurrentHashMap<>());
    private Object nsd; // NsdManager.RegistrationListener
    // pairing: one at a time, and a pause after a run of failed ones (no code spam on the screen)
    private Session pairing;
    private final long[] fails = new long[3];
    private int fi;

    private LanRemote(Context c) { ctx = c; }

    private synchronized void start() {
        if (server != null) return;
        try {
            ServerSocket s = new ServerSocket();
            s.setReuseAddress(true);
            s.bind(new java.net.InetSocketAddress(PORT), 4);
            server = s;
        } catch (Throwable t) {
            HomeKeyService.log("lan: no port: " + t);
            return;
        }
        Thread th = new Thread(this::serve, "tvc-lan");
        th.setDaemon(true);
        th.start();
        advertise(true);
        HomeKeyService.log("lan: listening on " + PORT);
    }

    private synchronized void stop() {
        ServerSocket s = server;
        server = null;
        try { if (s != null) s.close(); } catch (Throwable ignored) {}
        advertise(false);
        dropAll();
    }

    private void dropAll() {
        for (Socket c : live) {
            try { c.close(); } catch (Throwable ignored) {}
        }
    }

    private void serve() {
        while (true) {
            ServerSocket ss = server;
            if (ss == null) return;
            final Socket s;
            try {
                s = ss.accept();
            } catch (Throwable t) {
                if (server == null) return;
                SystemClock.sleep(500);
                continue;
            }
            synchronized (this) {
                if (clients >= MAX_CLIENTS) {
                    try { s.close(); } catch (Throwable ignored) {}
                    continue;
                }
                clients++;
            }
            live.add(s);
            Thread t = new Thread(() -> {
                try {
                    new Session(s).run();
                } catch (Throwable e) {
                    HomeKeyService.log("lan: " + e);
                } finally {
                    try { s.close(); } catch (Throwable ignored) {}
                    live.remove(s);
                    synchronized (LanRemote.this) { clients--; }
                }
            }, "tvc-lan-client");
            t.setDaemon(true);
            t.start();
        }
    }

    /** The TV on the network as «_tvcleanzer._tcp», so the phone finds it when its address changed. */
    private void advertise(boolean on) {
        try {
            android.net.nsd.NsdManager nm = (android.net.nsd.NsdManager) ctx.getSystemService(Context.NSD_SERVICE);
            if (nm == null) return;
            if (!on) {
                if (nsd != null) nm.unregisterService((android.net.nsd.NsdManager.RegistrationListener) nsd);
                nsd = null;
                return;
            }
            if (nsd != null) return;
            android.net.nsd.NsdServiceInfo si = new android.net.nsd.NsdServiceInfo();
            si.setServiceName(deviceName());
            si.setServiceType("_tvcleanzer._tcp");
            si.setPort(PORT);
            android.net.nsd.NsdManager.RegistrationListener l = new android.net.nsd.NsdManager.RegistrationListener() {
                @Override public void onRegistrationFailed(android.net.nsd.NsdServiceInfo i, int e) { nsd = null; }
                @Override public void onUnregistrationFailed(android.net.nsd.NsdServiceInfo i, int e) {}
                @Override public void onServiceRegistered(android.net.nsd.NsdServiceInfo i) {}
                @Override public void onServiceUnregistered(android.net.nsd.NsdServiceInfo i) {}
            };
            nsd = l;
            nm.registerService(si, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, l);
        } catch (Throwable t) {
            nsd = null;
            HomeKeyService.log("lan: nsd " + t);
        }
    }

    private String deviceName() {
        String n = null;
        try { n = android.provider.Settings.Global.getString(ctx.getContentResolver(), "device_name"); } catch (Throwable ignored) {}
        if (n == null || n.trim().isEmpty()) n = android.os.Build.MODEL;
        return n == null || n.trim().isEmpty() ? "TV" : n.trim();
    }

    private SharedPreferences store() { return ctx.getSharedPreferences("lan", Context.MODE_PRIVATE); }

    // ── one phone ───────────────────────────────────────────────────────────────────────

    private final class Session implements LanProto.Io, LanProto.Host {
        private final Socket sock;
        private final Out out;
        private final BufferedReader in;
        private final LanProto proto = new LanProto(rnd);

        Session(Socket s) throws IOException {
            sock = s;
            s.setTcpNoDelay(true);
            s.setSoTimeout(30_000);
            out = new Out(s.getOutputStream());
            in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8), 4096);
        }

        void run() throws Exception {
            out.line(proto.hello(android.os.Build.VERSION.SDK_INT, deviceName()));
            if (!proto.handshake(this, this)) return;
            store().edit().putLong("t_" + proto.id, System.currentTimeMillis()).apply();
            sock.setSoTimeout(45_000); // the phone pings every 15 s
            HomeKeyService.log("lan: phone " + proto.id + " in");
            state();
            try {
                String l;
                while ((l = read()) != null) {
                    String cmd = proto.verify(l);
                    if (cmd == null) {
                        out.line("err mac");
                        return;
                    }
                    command(cmd);
                }
            } finally {
                Mouse m = mouse();
                if (m != null) m.release(out);
                HomeKeyService.log("lan: phone " + proto.id + " out");
            }
        }

        /** A line, at most 8 KB (a long text); null at the end. */
        @Override public String read() throws IOException {
            String l = in.readLine();
            if (l != null && l.length() > 8192) throw new IOException("line too long");
            return l;
        }

        @Override public void line(String s) throws IOException { out.line(s); }
        @Override public void slow() throws IOException { sock.setSoTimeout((int) PAIR_MS); }

        @Override public byte[] key(String id) {
            String k = store().getString("k_" + id, null);
            return k == null ? null : LanProto.unhexOr(k);
        }

        @Override public String pairStart() {
            synchronized (LanRemote.this) {
                long now = SystemClock.elapsedRealtime();
                long oldest = Long.MAX_VALUE;
                for (long f : fails) oldest = Math.min(oldest, f);
                if (oldest > 0 && now - oldest < 10 * 60_000) return "later";
                if (pairing != null) return "busy";
                pairing = this;
                return null;
            }
        }

        @Override public void pairEnd(boolean failed) {
            synchronized (LanRemote.this) {
                if (pairing == this) pairing = null;
                if (failed) fails[fi++ % fails.length] = SystemClock.elapsedRealtime();
            }
        }

        @Override public void showCode(String code, String phone) { CodeBadge.show(ctx, code, phone); }
        @Override public void codeDone(boolean ok) { CodeBadge.done(ctx, ok); }

        @Override public void keep(String phone, byte[] k, String name) {
            SharedPreferences sp = store();
            Map<String, ?> all = sp.getAll();
            // the phones used longest ago go when there are too many
            java.util.List<String> others = new java.util.ArrayList<>();
            for (String key : all.keySet()) {
                if (key.startsWith("k_") && !key.equals("k_" + phone)) others.add(key.substring(2));
            }
            java.util.Collections.sort(others, (x, y) -> Long.compare(used(all, x), used(all, y)));
            SharedPreferences.Editor e = sp.edit();
            for (int i = 0; i < others.size() - (MAX_PHONES - 1); i++) {
                String old = others.get(i);
                e.remove("k_" + old).remove("t_" + old).remove("n_" + old);
            }
            e.putString("k_" + phone, LanProto.hex(k)).putString("n_" + phone, name)
                    .putLong("t_" + phone, System.currentTimeMillis()).commit();
        }

        private long used(Map<String, ?> all, String phone) {
            Object v = all.get("t_" + phone);
            return v instanceof Long ? (Long) v : 0;
        }

        private void command(String c) throws IOException {
            if (c.isEmpty()) return;
            int sp = c.indexOf(' ');
            String op = sp < 0 ? c : c.substring(0, sp), arg = sp < 0 ? "" : c.substring(sp + 1);
            switch (op) {
                case "p": out.line("pong"); return;
                case "?": state(); return;
                case "k": if (!press(arg)) out.line("no k " + arg); else if (arg.startsWith("vol") || arg.equals("mute")) state(); return;
                case "t": out.line(text(LanProto.dec(arg), false) ? "t ok" : "no t"); return;
                case "tx": out.line(text(LanProto.dec(arg), true) ? "t ok" : "no t"); return;
                case "a": out.line(app(arg) ? "a ok" : "no a " + arg); return;
                case "u": out.line(link(LanProto.dec(arg)) ? "u ok" : "no u"); return;
                case "v": volume(arg); state(); return;
                case "m": case "c": case "l": case "s": case "e": {
                    Mouse m = mouse();
                    if (m == null) out.line("no mouse");
                    else m.feed(c, out);
                    return;
                }
                default: out.line("no " + op);
            }
        }

        /** What this TV can do from here, for the phone's remote screen. */
        private void state() throws IOException {
            AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            HomeKeyService s = HomeKeyService.running;
            int v = am.getStreamVolume(AudioManager.STREAM_MUSIC), max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            boolean muted = android.os.Build.VERSION.SDK_INT >= 23 && am.isStreamMute(AudioManager.STREAM_MUSIC);
            String app = s != null ? s.frontPackageNow() : null;
            out.line("st svc=" + (s != null ? 1 : 0)
                    + " dpad=" + (s != null ? 1 : 0)
                    + " text=" + (s != null ? 1 : 0)
                    + " mouse=" + (s != null && android.os.Build.VERSION.SDK_INT >= 24 ? 1 : 0)
                    + " vol=" + v + "/" + max + " muted=" + (muted ? 1 : 0)
                    + " app=" + (app == null ? "-" : app));
        }
    }

    private Mouse mouse() {
        HomeKeyService s = HomeKeyService.running;
        return s != null && android.os.Build.VERSION.SDK_INT >= 24 ? s.mouse() : null;
    }

    // ── what the commands do ────────────────────────────────────────────────────────────

    /** A key by name. Without the Home-key service only what any app may do works here:
     *  home, media, volume, settings. */
    private boolean press(String k) {
        HomeKeyService s = HomeKeyService.running;
        switch (k) {
            case "home":
                return onMain(() -> {
                    Intent i = new Intent(ctx, HomeActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                    ctx.startActivity(i);
                });
            case "settings":
                return onMain(() -> ctx.startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)));
            case "playpause": return media(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE);
            case "play": return media(KeyEvent.KEYCODE_MEDIA_PLAY);
            case "pause": return media(KeyEvent.KEYCODE_MEDIA_PAUSE);
            case "stop": return media(KeyEvent.KEYCODE_MEDIA_STOP);
            case "next": return media(KeyEvent.KEYCODE_MEDIA_NEXT);
            case "prev": return media(KeyEvent.KEYCODE_MEDIA_PREVIOUS);
            case "ff": return media(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD);
            case "rew": return media(KeyEvent.KEYCODE_MEDIA_REWIND);
            case "volup": return adjust(AudioManager.ADJUST_RAISE);
            case "voldown": return adjust(AudioManager.ADJUST_LOWER);
            case "mute":
                return adjust(android.os.Build.VERSION.SDK_INT >= 23 ? AudioManager.ADJUST_TOGGLE_MUTE : AudioManager.ADJUST_SAME);
            default: break;
        }
        if (s == null) return false;
        switch (k) {
            case "back": return global(s, AccessibilityService.GLOBAL_ACTION_BACK);
            case "recents": return global(s, AccessibilityService.GLOBAL_ACTION_RECENTS);
            case "notifications": return global(s, AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS);
            case "power": return global(s, AccessibilityService.GLOBAL_ACTION_POWER_DIALOG);
            case "up": return dpad(s, 16, android.view.View.FOCUS_UP);
            case "down": return dpad(s, 17, android.view.View.FOCUS_DOWN);
            case "left": return dpad(s, 18, android.view.View.FOCUS_LEFT);
            case "right": return dpad(s, 19, android.view.View.FOCUS_RIGHT);
            case "ok": return dpad(s, 20, 0);
            default: return false;
        }
    }

    private boolean onMain(Runnable r) {
        main.post(() -> {
            try { r.run(); } catch (Throwable t) { HomeKeyService.log("lan: " + t); }
        });
        return true;
    }

    private boolean global(HomeKeyService s, int action) {
        return onMain(() -> s.performGlobalAction(action));
    }

    /** Arrows and OK: the system's own D-pad actions on Android 13+, below that the focus moved
     *  (and clicked) through the screen's accessibility tree — fine in menus and lists. */
    private boolean dpad(HomeKeyService s, int action, int dir) {
        if (android.os.Build.VERSION.SDK_INT >= 33) return global(s, action);
        return onMain(() -> {
            AccessibilityNodeInfo root = s.getRootInActiveWindow();
            if (root == null) return;
            AccessibilityNodeInfo f = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (dir == 0) {
                AccessibilityNodeInfo n = f;
                while (n != null && !n.isClickable()) n = n.getParent();
                if (n != null) n.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                return;
            }
            AccessibilityNodeInfo next = f != null ? f.focusSearch(dir) : firstFocusable(root, 0);
            if (next != null) next.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
        });
    }

    private static AccessibilityNodeInfo firstFocusable(AccessibilityNodeInfo n, int depth) {
        if (n == null || depth > 30) return null;
        if (n.isFocusable() && n.isVisibleToUser()) return n;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo r = firstFocusable(n.getChild(i), depth + 1);
            if (r != null) return r;
        }
        return null;
    }

    private boolean media(int code) {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        long t = SystemClock.uptimeMillis();
        am.dispatchMediaKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0));
        am.dispatchMediaKeyEvent(new KeyEvent(t, t + 20, KeyEvent.ACTION_UP, code, 0));
        return true;
    }

    private boolean adjust(int dir) {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        am.adjustStreamVolume(AudioManager.STREAM_MUSIC, dir, AudioManager.FLAG_SHOW_UI);
        return true;
    }

    private void volume(String a) {
        try {
            AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            int max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            int v = Math.max(0, Math.min(max, Integer.parseInt(a.trim())));
            am.setStreamVolume(AudioManager.STREAM_MUSIC, v, AudioManager.FLAG_SHOW_UI);
        } catch (Throwable t) {
            HomeKeyService.log("lan: volume " + t);
        }
    }

    /** Puts [s] into the text field in focus (the whole field), [enter] then sends it. */
    private boolean text(String s, boolean enter) {
        HomeKeyService svc = HomeKeyService.running;
        if (svc == null) return false;
        final boolean[] done = {false};
        final java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(1);
        main.post(() -> {
            try {
                AccessibilityNodeInfo root = svc.getRootInActiveWindow();
                AccessibilityNodeInfo f = root == null ? null : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                if (f != null && f.isEditable()) {
                    Bundle b = new Bundle();
                    b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, s);
                    done[0] = f.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b);
                    if (done[0] && enter && android.os.Build.VERSION.SDK_INT >= 30) {
                        f.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.getId());
                    }
                }
            } catch (Throwable t) {
                HomeKeyService.log("lan: text " + t);
            }
            latch.countDown();
        });
        try { latch.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS); } catch (InterruptedException ignored) {}
        return done[0];
    }

    private boolean app(String pkg) {
        if (!pkg.matches("[A-Za-z0-9_.]{1,200}")) return false;
        android.content.pm.PackageManager pm = ctx.getPackageManager();
        Intent i = null;
        try { i = pm.getLeanbackLaunchIntentForPackage(pkg); } catch (Throwable ignored) {}
        if (i == null) i = pm.getLaunchIntentForPackage(pkg);
        if (i == null) return false;
        final Intent go = i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return onMain(() -> ctx.startActivity(go));
    }

    private boolean link(String url) {
        Uri u = Uri.parse(url);
        String sc = u.getScheme();
        if (sc == null || !(sc.equals("https") || sc.equals("http") || sc.equals("market"))) return false;
        return onMain(() -> ctx.startActivity(new Intent(Intent.ACTION_VIEW, u).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)));
    }

    // ── the code on the TV screen ───────────────────────────────────────────────────────

    /** The pairing code over whatever is on screen: the Home-key service's own layer, else a
     *  «draw over apps» window, else repeated toasts (a box with neither). */
    static final class CodeBadge {
        private static View view;
        private static WindowManager wm;
        private static final Handler h = new Handler(Looper.getMainLooper());
        private static int toastRun;

        static void show(Context c, String code, String phone) {
            h.post(() -> {
                remove();
                String spaced = code.substring(0, 3) + " " + code.substring(3);
                HomeKeyService s = HomeKeyService.running;
                Context base = s != null ? s : c;
                int type;
                if (s != null) type = WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY;
                else if (Mouse.canOverlay(c)) type = android.os.Build.VERSION.SDK_INT >= 26
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY : WindowManager.LayoutParams.TYPE_PHONE;
                else {
                    toasts(c, T.f("Код для телефона: {0}", spaced), ++toastRun, (int) (PAIR_MS / 3500));
                    return;
                }
                try {
                    View v = card(base, spaced, phone);
                    WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, type,
                            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                            PixelFormat.TRANSLUCENT);
                    lp.gravity = Gravity.CENTER;
                    wm = (WindowManager) base.getSystemService(Context.WINDOW_SERVICE);
                    wm.addView(v, lp);
                    view = v;
                    h.postDelayed(CodeBadge::remove, PAIR_MS);
                } catch (Throwable t) {
                    HomeKeyService.log("lan: badge " + t);
                    toasts(c, T.f("Код для телефона: {0}", spaced), ++toastRun, (int) (PAIR_MS / 3500));
                }
            });
        }

        static void done(Context c, boolean ok) {
            h.post(() -> {
                toastRun++;
                remove();
                if (ok) Toast.makeText(c, T.t("Телефон подключён"), Toast.LENGTH_SHORT).show();
            });
        }

        private static void toasts(Context c, String text, int run, int left) {
            if (run != toastRun || left <= 0) return;
            Toast.makeText(c, text, Toast.LENGTH_LONG).show();
            h.postDelayed(() -> toasts(c, text, run, left - 1), 3600);
        }

        private static void remove() {
            h.removeCallbacksAndMessages(null);
            if (view != null && wm != null) {
                try { wm.removeView(view); } catch (Throwable ignored) {}
            }
            view = null;
        }

        private static View card(Context c, String code, String phone) {
            float dp = c.getResources().getDisplayMetrics().density;
            LinearLayout box = new LinearLayout(c);
            box.setOrientation(LinearLayout.VERTICAL);
            box.setGravity(Gravity.CENTER_HORIZONTAL);
            int pad = Math.round(28 * dp);
            box.setPadding(pad, Math.round(22 * dp), pad, Math.round(22 * dp));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(0xF0181C24);
            bg.setCornerRadius(20 * dp);
            bg.setStroke(Math.round(1 * dp), 0x33FFFFFF);
            box.setBackground(bg);
            TextView title = new TextView(c);
            title.setText(T.t("Код для телефона"));
            title.setTextColor(0xCCFFFFFF);
            title.setTextSize(18);
            box.addView(title);
            TextView big = new TextView(c);
            big.setText(code);
            big.setTextColor(0xFFFFFFFF);
            big.setTextSize(56);
            big.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
            big.setLetterSpacing(0.08f);
            box.addView(big);
            TextView sub = new TextView(c);
            sub.setText(phone == null || phone.isEmpty()
                    ? T.t("Введите его в TVCleanzer на телефоне")
                    : T.f("Введите его в TVCleanzer на телефоне «{0}»", phone));
            sub.setTextColor(0x99FFFFFF);
            sub.setTextSize(15);
            sub.setGravity(Gravity.CENTER);
            sub.setMaxWidth(Math.round(420 * dp));
            box.addView(sub);
            return box;
        }
    }

    // ── bits ───────────────────────────────────────────────────────────────────────────

    /** Writes whole lines; the mouse writes through it too, so lines never mix. */
    static final class Out extends OutputStream {
        private final OutputStream o;
        Out(OutputStream o) { this.o = o; }
        synchronized void line(String s) throws IOException {
            o.write((s + "\n").getBytes(StandardCharsets.UTF_8));
            o.flush();
        }
        @Override public synchronized void write(int b) throws IOException { o.write(b); }
        @Override public synchronized void write(byte[] b, int off, int len) throws IOException { o.write(b, off, len); }
        @Override public synchronized void flush() throws IOException { o.flush(); }
    }

}
