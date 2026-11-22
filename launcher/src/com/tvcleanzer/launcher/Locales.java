package com.tvcleanzer.launcher;

import android.content.res.Configuration;
import android.os.Build;
import android.os.LocaleList;

import java.lang.reflect.Method;
import java.util.Locale;

/**
 * Changes the TV's system language (0.59). Android lets an app do it once ADB has granted it
 * CHANGE_CONFIGURATION (`pm grant`), the way MoreLocale and «ADB Change Language» work: for
 * Chinese Xiaomi firmwares that came back in Chinese after a reset (MiTV-MFTR0), and for owners
 * whose TV has no language they read in its own menu.
 */
final class Locales {
    private Locales() {}

    /** "ok", or why not (for the phone's «?» report). */
    static String apply(String tag) {
        if (tag == null || !tag.matches("[a-z]{2,3}(-[A-Z]{2})?")) return "bad tag";
        Locale loc = Locale.forLanguageTag(tag);
        exemptHiddenApi();
        String err = "";
        if (Build.VERSION.SDK_INT >= 24) {
            try {
                Class<?> picker = Class.forName("com.android.internal.app.LocalePicker");
                picker.getMethod("updateLocales", LocaleList.class).invoke(null, new LocaleList(loc));
                return "ok";
            } catch (Throwable t) {
                err = "picker: " + why(t) + "; ";
            }
        }
        try {
            Object am = activityManager();
            Configuration c = (Configuration) am.getClass().getMethod("getConfiguration").invoke(am);
            if (Build.VERSION.SDK_INT >= 24) c.setLocales(new LocaleList(loc));
            else c.locale = loc;
            try {
                Configuration.class.getField("userSetLocale").setBoolean(c, true);
            } catch (Throwable ignored) {}
            am.getClass().getMethod("updatePersistentConfiguration", Configuration.class).invoke(am, c);
            return "ok";
        } catch (Throwable t) {
            return err + "am: " + why(t);
        }
    }

    private static Object activityManager() throws Exception {
        if (Build.VERSION.SDK_INT >= 26) {
            return android.app.ActivityManager.class.getMethod("getService").invoke(null);
        }
        return Class.forName("android.app.ActivityManagerNative").getMethod("getDefault").invoke(null);
    }

    /** Android 9–10: lifts the hidden-API check for this app (meta-reflection); harmless elsewhere. */
    private static void exemptHiddenApi() {
        if (Build.VERSION.SDK_INT < 28) return;
        try {
            Method forName = Class.class.getDeclaredMethod("forName", String.class);
            Method declared = Class.class.getDeclaredMethod("getDeclaredMethod", String.class, Class[].class);
            Class<?> vm = (Class<?>) forName.invoke(null, "dalvik.system.VMRuntime");
            Method runtime = (Method) declared.invoke(vm, "getRuntime", new Class<?>[0]);
            Method exempt = (Method) declared.invoke(vm, "setHiddenApiExemptions", new Class<?>[] {String[].class});
            exempt.invoke(runtime.invoke(null), new Object[] {new String[] {"L"}});
        } catch (Throwable ignored) {}
    }

    private static String why(Throwable t) {
        Throwable c = t.getCause() != null ? t.getCause() : t; // InvocationTargetException
        String m = c.getClass().getSimpleName() + (c.getMessage() == null ? "" : ": " + c.getMessage());
        return m.length() > 160 ? m.substring(0, 160) : m;
    }
}
