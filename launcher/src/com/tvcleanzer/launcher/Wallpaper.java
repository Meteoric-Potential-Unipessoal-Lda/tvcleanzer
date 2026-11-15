package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import java.io.File;

/**
 * Own photo as the background. The phone app writes it over ADB:
 *   content write --uri content://com.tvcleanzer.launcher.state/wallpaper  (launcher 0.4+, Android 10+)
 * or, on older setups, straight into the app's external files dir.
 */
final class Wallpaper {
    private Wallpaper() {}

    /** Where StateProvider stores an uploaded photo (private, survives scoped storage). */
    static File internal(Context c) { return new File(c.getFilesDir(), "wallpaper.jpg"); }

    /** Old location (launcher 0.3 and Android 7–9 upload path). */
    static File legacy(Context c) {
        File dir = c.getExternalFilesDir(null);
        return dir == null ? null : new File(dir, "wallpaper.jpg");
    }

    /** The photo in use: the newest of the two locations. */
    static File file(Context c) {
        File a = internal(c), b = legacy(c);
        boolean ha = a.exists() && a.length() > 0, hb = b != null && b.exists() && b.length() > 0;
        if (ha && hb) return a.lastModified() >= b.lastModified() ? a : b;
        if (hb) return b;
        return a;
    }

    static boolean exists(Context c) {
        File f = file(c);
        return f.exists() && f.length() > 0;
    }

    static void delete(Context c) {
        //noinspection ResultOfMethodCallIgnored
        internal(c).delete();
        File b = legacy(c);
        //noinspection ResultOfMethodCallIgnored
        if (b != null) b.delete();
    }

    /** Decoded close to screen size to keep memory low on 1 GB TVs. */
    static Bitmap load(Context c) {
        return decode(c, file(c));
    }

    static Bitmap decode(Context c, File f) {
        if (f == null || !f.exists() || f.length() == 0) return null;
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(f.getAbsolutePath(), o);
            if (o.outWidth <= 0 || o.outHeight <= 0) return null; // not an image we can read
            int target = Math.max(1280, c.getResources().getDisplayMetrics().widthPixels);
            int sample = 1;
            while (o.outWidth / (sample * 2) >= target) sample *= 2;
            BitmapFactory.Options d = new BitmapFactory.Options();
            d.inSampleSize = sample;
            d.inPreferredConfig = Bitmap.Config.RGB_565; // half the memory, fine for photos
            return BitmapFactory.decodeFile(f.getAbsolutePath(), d);
        } catch (Throwable t) {
            return null;
        }
    }
}
