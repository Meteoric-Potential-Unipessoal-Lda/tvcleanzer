package com.tvcleanzer.launcher;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.tv.TvInputService;
import android.os.Build;

/**
 * 1.43: a TV input that plays nothing, switched on only on TCL. TCL's boot manager takes the
 * «start on its own» right (the AUTO_START app-op) from apps on every boot: our Home-key service
 * is not bound and BOOT_COMPLETED never comes (TCL 55C745: «после перезагрузки слетает»). It lets
 * apps that provide a TV input through. The idea is from couch-tv (github.com/Seagey/couch-tv,
 * MIT, TclPlaceholderInput, issue #94); unverified on a real TCL there too.
 *
 * Off in the manifest, so no other TV lists a new source; switched on at the launcher's first
 * start on a TCL (Android keeps it over reboots). Inputs leaves it out of our own source list.
 */
public class TclInput extends TvInputService {
    @Override
    public Session onCreateSession(String inputId) {
        return null; // nothing ever plays
    }

    static boolean isTcl() {
        return "TCL".equalsIgnoreCase(Build.MANUFACTURER) || "TCL".equalsIgnoreCase(Build.BRAND);
    }

    /** Switches the input on, on a TCL only. Safe to call on every start. */
    static void ensure(Context c) {
        if (!isTcl() || Build.VERSION.SDK_INT < 21) return;
        try {
            PackageManager pm = c.getPackageManager();
            ComponentName me = new ComponentName(c, TclInput.class);
            if (pm.getComponentEnabledSetting(me) != PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                pm.setComponentEnabledSetting(me, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP);
                HomeKeyService.log("tcl: the placeholder TV input switched on (boot start)");
            }
        } catch (Throwable t) {
            HomeKeyService.log("tcl: " + t);
        }
    }
}
