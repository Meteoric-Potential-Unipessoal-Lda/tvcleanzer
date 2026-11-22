package com.tvcleanzer.launcher;

import android.content.Context;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Music for the photo frame: tracks the phone sends (0.61+), played while the frame is on screen.
 *   content write --uri content://com.tvcleanzer.launcher.state/music/mp3 < song.mp3   (Android 10+)
 * or a copy into the app's external files dir, music/ (older Android).
 * At most [MAX] tracks and [MAX_BYTES] together: the newest are kept.
 */
final class Music {
    private Music() {}

    static final int MAX = 30;
    static final long MAX_BYTES = 400L * 1024 * 1024;
    private static final String[] EXT = {"mp3", "m4a", "aac", "ogg", "oga", "opus", "flac", "wav"};

    static File dir(Context c) {
        File d = new File(c.getFilesDir(), "music");
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();
        return d;
    }

    static File legacyDir(Context c) {
        File e = c.getExternalFilesDir(null);
        return e == null ? null : new File(e, "music");
    }

    static boolean isTrack(String name) {
        String n = name.toLowerCase();
        for (String e : EXT) if (n.endsWith("." + e)) return true;
        return false;
    }

    /** A new file for the next upload (StateProvider); [ext] comes from the phone. */
    static synchronized File newFile(Context c, String ext) {
        String e = ext == null ? "" : ext.toLowerCase();
        if (!isTrack("x." + e)) e = "mp3";
        File d = dir(c);
        long t = System.currentTimeMillis();
        File f;
        do { f = new File(d, "m" + (t++) + "." + e); } while (f.exists());
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
        for (File f : fs) if (f.isFile() && f.length() > 0 && isTrack(f.getName())) out.add(f);
    }

    static int count(Context c) { return list(c).size(); }

    static void clear(Context c) {
        for (File f : list(c)) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    /** Keeps the newest [MAX] tracks, no more than [MAX_BYTES] together. */
    static void trim(Context c) {
        List<File> all = list(c);
        long total = 0;
        int kept = 0;
        for (int i = all.size() - 1; i >= 0; i--) {
            File f = all.get(i);
            if (kept < MAX && total + f.length() <= MAX_BYTES) {
                kept++;
                total += f.length();
            } else {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        }
    }
}
