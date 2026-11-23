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
