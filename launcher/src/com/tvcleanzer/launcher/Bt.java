package com.tvcleanzer.launcher;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.content.Context;
import android.os.Build;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * Bluetooth in the top bar (0.63, asked in the chat): is it on, what is connected, and
 * switching it. What is connected needs BLUETOOTH_CONNECT on Android 12+, which the phone
 * app grants over ADB (pm grant); without it the pill just says on or off.
 */
final class Bt {
    private Bt() {}

    static final int NONE = 0, OFF = 1, ON = 2, CONNECTED = 3;

    static BluetoothAdapter adapter(Context c) {
        try {
            BluetoothManager m = (BluetoothManager) c.getSystemService(Context.BLUETOOTH_SERVICE);
            return m == null ? null : m.getAdapter();
        } catch (Throwable t) {
            return null;
        }
    }

    /** NONE: the TV has no Bluetooth (the pill is not shown). */
    static int state(Context c) {
        BluetoothAdapter a = adapter(c);
        if (a == null) return NONE;
        try {
            if (!a.isEnabled()) return OFF;
        } catch (Throwable t) {
            return NONE;
        }
        return connected(c, false).isEmpty() ? ON : CONNECTED;
    }

    /** Names of the connected devices; only remotes, keyboards and gamepads with [inputOnly]. */
    @SuppressWarnings("MissingPermission")
    static List<String> connected(Context c, boolean inputOnly) {
        List<String> out = new ArrayList<>();
        BluetoothAdapter a = adapter(c);
        if (a == null) return out;
        try {
            if (!a.isEnabled()) return out;
            // public since forever, hidden from the SDK: the one call that says «connected now»
            Method isConnected = BluetoothDevice.class.getMethod("isConnected");
            for (BluetoothDevice d : a.getBondedDevices()) {
                try {
                    if (!Boolean.TRUE.equals(isConnected.invoke(d))) continue;
                    if (inputOnly) {
                        BluetoothClass bc = d.getBluetoothClass();
                        if (bc == null || bc.getMajorDeviceClass() != BluetoothClass.Device.Major.PERIPHERAL) continue;
                    }
                    String n = d.getName();
                    out.add(n == null || n.trim().isEmpty() ? d.getAddress() : n.trim());
                } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}
        return out;
    }

    /** 1.46: the lowest charge, percent, among the connected devices that tell it (a remote first:
     *  input devices are looked at before the rest); -1 when none tells. BluetoothDevice's
     *  getBatteryLevel is hidden from the SDK but public on Android 8.1+ (as couch-tv reads it). */
    @SuppressWarnings("MissingPermission")
    static int battery(Context c) {
        BluetoothAdapter a = adapter(c);
        if (a == null) return -1;
        if (Build.VERSION.SDK_INT < 27) return legacyBattery(c);
        try {
            if (!a.isEnabled()) return -1;
            Method isConnected = BluetoothDevice.class.getMethod("isConnected");
            Method level = BluetoothDevice.class.getMethod("getBatteryLevel");
            int input = -1, any = -1;
            for (BluetoothDevice d : a.getBondedDevices()) {
                try {
                    if (!Boolean.TRUE.equals(isConnected.invoke(d))) continue;
                    int l = (Integer) level.invoke(d);
                    if (l < 0 || l > 100) continue;
                    BluetoothClass bc = d.getBluetoothClass();
                    boolean in = bc != null && bc.getMajorDeviceClass() == BluetoothClass.Device.Major.PERIPHERAL;
                    if (in) input = input < 0 ? l : Math.min(input, l);
                    any = any < 0 ? l : Math.min(any, l);
                } catch (Throwable ignored) {}
            }
            int got = input >= 0 ? input : any;
            // 1.52: Android 8.1–12 knows only headsets' charge (a Xiaomi MSSP1: the TV's settings
            // said «Батарея 85%», we nothing) — the remote's own battery service then
            return got >= 0 ? got : legacyBattery(c); // 1.54: any version (Roman: none on a newer TV)
        } catch (Throwable t) {
            return -1;
        }
    }

    /** «Пульт · 80%» for each connected device that tells its charge (the Bluetooth menu). */
    @SuppressWarnings("MissingPermission")
    static List<String> withBattery(Context c) {
        List<String> out = new ArrayList<>();
        BluetoothAdapter a = adapter(c);
        if (a == null) return out;
        try {
            if (!a.isEnabled()) return out;
            Method isConnected = BluetoothDevice.class.getMethod("isConnected");
            Method level = Build.VERSION.SDK_INT >= 27 ? BluetoothDevice.class.getMethod("getBatteryLevel") : null;
            for (BluetoothDevice d : a.getBondedDevices()) {
                try {
                    if (!Boolean.TRUE.equals(isConnected.invoke(d))) continue;
                    String n = d.getName();
                    n = n == null || n.trim().isEmpty() ? d.getAddress() : n.trim();
                    int l = level == null ? -1 : (Integer) level.invoke(d);
                    if (l < 0 || l > 100) l = legacyLevel(d.getAddress());
                    out.add(l >= 0 && l <= 100 ? n + " · " + l + "%" : n);
                } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}
        return out;
    }

    // ── 1.48: the charge before Android 8.1 (a Hyundai on Android 7.1: the TV's settings showed the
    // remote's percent, the home screen nothing). First the kernel's HID battery
    // (/sys/class/power_supply/hid-…-battery), then the remote's own Bluetooth LE battery
    // service (0x180F), read now and then and kept. ──

    private static final java.util.Map<String, Integer> gattLevels = new java.util.HashMap<>();
    private static volatile long gattAt;
    private static volatile boolean gattBusy;
    private static final java.util.UUID BATTERY_SVC = java.util.UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb");
    private static final java.util.UUID BATTERY_LVL = java.util.UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb");

    private static int legacyLevel(String address) {
        synchronized (gattLevels) {
            Integer l = address == null ? null : gattLevels.get(address);
            if (l != null) return l;
        }
        return -1;
    }

    static int legacyBattery(Context c) {
        int s = sysfsBattery();
        if (s >= 0) return s;
        synchronized (gattLevels) {
            int low = -1;
            for (int l : gattLevels.values()) low = low < 0 ? l : Math.min(low, l);
            return low;
        }
    }

    private static int sysfsBattery() {
        try {
            java.io.File[] all = new java.io.File("/sys/class/power_supply").listFiles();
            if (all == null) return -1;
            int low = -1;
            for (java.io.File f : all) {
                String scope = read(new java.io.File(f, "scope"));
                if (!f.getName().startsWith("hid-") && !"Device".equalsIgnoreCase(scope)) continue;
                String cap = read(new java.io.File(f, "capacity"));
                if (cap == null) continue;
                int l = Integer.parseInt(cap.trim());
                if (l < 0 || l > 100) continue;
                low = low < 0 ? l : Math.min(low, l);
            }
            return low;
        } catch (Throwable t) {
            return -1;
        }
    }

    private static String read(java.io.File f) {
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            return r.readLine();
        } catch (Throwable t) {
            return null;
        }
    }

    /** Reads the battery service of the connected LE remotes (Android 7–12), at most every
     *  10 minutes; [done] on the main thread when a level came. */
    @SuppressWarnings("MissingPermission")
    static void refreshLegacy(Context c, final Runnable done) {
        if (gattBusy) return;
        long now = System.currentTimeMillis();
        if (now - gattAt < 10 * 60_000L) return;
        gattAt = now;
        if (sysfsBattery() >= 0) return;
        final BluetoothAdapter a = adapter(c);
        if (a == null) return;
        final Context app = c.getApplicationContext();
        final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
        try {
            if (!a.isEnabled()) return;
            Method isConnected = BluetoothDevice.class.getMethod("isConnected");
            final List<BluetoothDevice> todo = new ArrayList<>();
            for (BluetoothDevice d : a.getBondedDevices()) {
                try {
                    if (d.getType() == BluetoothDevice.DEVICE_TYPE_CLASSIC) continue;
                    if (Boolean.TRUE.equals(isConnected.invoke(d))) todo.add(d);
                } catch (Throwable ignored) {}
            }
            if (todo.isEmpty()) return;
            gattBusy = true;
            main.post(() -> readNext(app, main, todo, done, false));
        } catch (Throwable t) {
            gattBusy = false;
        }
    }

    @SuppressWarnings("MissingPermission")
    private static void readNext(final Context app, final android.os.Handler main, final List<BluetoothDevice> todo,
                                 final Runnable done, final boolean gotAny) {
        if (todo.isEmpty()) {
            gattBusy = false;
            if (gotAny && done != null) done.run();
            return;
        }
        final BluetoothDevice d = todo.remove(0);
        final boolean[] over = {false};
        final android.bluetooth.BluetoothGatt[] held = {null};
        final Runnable finish = new Runnable() {
            @Override public void run() {
                if (over[0]) return;
                over[0] = true;
                try { if (held[0] != null) held[0].close(); } catch (Throwable ignored) {}
                boolean any = gotAny;
                synchronized (gattLevels) { any |= gattLevels.containsKey(d.getAddress()); }
                readNext(app, main, todo, done, any);
            }
        };
        try {
            android.bluetooth.BluetoothGattCallback cb = new android.bluetooth.BluetoothGattCallback() {
                @Override public void onConnectionStateChange(android.bluetooth.BluetoothGatt g, int status, int state) {
                    if (state == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                        try { if (!g.discoverServices()) main.post(finish); } catch (Throwable t) { main.post(finish); }
                    } else {
                        main.post(finish);
                    }
                }
                @Override public void onServicesDiscovered(android.bluetooth.BluetoothGatt g, int status) {
                    try {
                        android.bluetooth.BluetoothGattService s = g.getService(BATTERY_SVC);
                        android.bluetooth.BluetoothGattCharacteristic ch = s == null ? null : s.getCharacteristic(BATTERY_LVL);
                        if (ch == null || !g.readCharacteristic(ch)) main.post(finish);
                    } catch (Throwable t) {
                        main.post(finish);
                    }
                }
                @Override public void onCharacteristicRead(android.bluetooth.BluetoothGatt g,
                                                           android.bluetooth.BluetoothGattCharacteristic ch, int status) {
                    try {
                        byte[] v = ch.getValue();
                        if (status == android.bluetooth.BluetoothGatt.GATT_SUCCESS && v != null && v.length > 0) {
                            int l = v[0] & 0xFF;
                            if (l <= 100) synchronized (gattLevels) { gattLevels.put(d.getAddress(), l); }
                        }
                    } catch (Throwable ignored) {}
                    main.post(finish);
                }
            };
            // the remote is already connected for its keys: this rides on that link, and close()
            // only lets go of our part of it
            held[0] = Build.VERSION.SDK_INT >= 23
                    ? d.connectGatt(app, false, cb, BluetoothDevice.TRANSPORT_LE)
                    : d.connectGatt(app, false, cb);
            if (held[0] == null) { main.post(finish); return; }
            main.postDelayed(finish, 8000);
        } catch (Throwable t) {
            main.post(finish);
        }
    }

    /** Switches Bluetooth where an app still may (Android 12 and older); false = do it in
     *  the TV's settings (Android 13+ gives this only to the system). */
    @SuppressWarnings({"deprecation", "MissingPermission"})
    static boolean set(Context c, boolean on) {
        if (Build.VERSION.SDK_INT >= 33) return false;
        BluetoothAdapter a = adapter(c);
        if (a == null) return false;
        try {
            return on ? a.enable() : a.disable();
        } catch (Throwable t) {
            return false;
        }
    }

    /** The pill's words after the dot: «Bluetooth · Пульт», «Bluetooth · выключен». */
    static String label(Context c, int state) {
        if (state == OFF) return "Bluetooth · " + T.t("выключен");
        if (state != CONNECTED) return "Bluetooth";
        List<String> names = connected(c, false);
        if (names.isEmpty()) return "Bluetooth";
        String first = names.get(0);
        if (first.length() > 18) first = first.substring(0, 17) + "…";
        return "Bluetooth · " + first + (names.size() > 1 ? " +" + (names.size() - 1) : "");
    }
}
