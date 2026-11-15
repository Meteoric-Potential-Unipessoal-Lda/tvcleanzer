package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Bitmap;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Photos for the photo frame (screensaver) and the changing home background. The phone app
 * sends them already scaled to ≤1920 px (a few hundred KB each), at most [MAX]; only the
 * one on screen is decoded, so even 1 GB TVs are fine.
 *   content write --uri content://com.tvcleanzer.launcher.state/photo < p.jpg   (Android 10+)
 * or a copy into the app's external files dir, photos/ (older Android).
 */
final class Photos {
    private Photos() {}

    static final int MAX = 30;

    static File dir(Context c) {
        File d = new File(c.getFilesDir(), "photos");
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();
        return d;
    }

    static File legacyDir(Context c) {
        File e = c.getExternalFilesDir(null);
        return e == null ? null : new File(e, "photos");
    }

    /** A new file for the next upload (StateProvider). */
    static synchronized File newFile(Context c) {
        File d = dir(c);
        long t = System.currentTimeMillis();
        File f;
        do { f = new File(d, "p" + (t++) + ".jpg"); } while (f.exists());
        return f;
    }

    static List<File> list(Context c) {
        List<File> out = new ArrayList<>();
        add(out, dir(c));
        add(out, legacyDir(c));
        Collections.sort(out, (a, b) -> a.getName().compareTo(b.getName()));
        return out;
    }

    private static void add(List<File> out, File d) {
        if (d == null) return;
        File[] fs = d.listFiles();
        if (fs == null) return;
        for (File f : fs) {
            String n = f.getName().toLowerCase();
            if (f.isFile() && f.length() > 0 && (n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png"))) out.add(f);
        }
    }

    static int count(Context c) { return list(c).size(); }

    static void clear(Context c) {
        for (File f : list(c)) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    /** Keeps the newest [MAX]. */
    static void trim(Context c) {
        List<File> all = list(c);
        for (int i = 0; i < all.size() - MAX; i++) {
            //noinspection ResultOfMethodCallIgnored
            all.get(i).delete();
        }
    }

    static Bitmap load(Context c, File f) { return Wallpaper.decode(c, f); }
}
