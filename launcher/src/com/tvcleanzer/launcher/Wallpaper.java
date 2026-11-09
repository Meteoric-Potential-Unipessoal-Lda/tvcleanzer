package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import java.io.File;

/** Own photo as the background. The phone app writes it over ADB. */
final class Wallpaper {
    private Wallpaper() {}

    static File file(Context c) {
        File dir = c.getExternalFilesDir(null);
        if (dir == null) dir = c.getFilesDir();
        return new File(dir, "wallpaper.jpg");
    }

    /** Decoded close to screen size to keep memory low on 1 GB TVs. */
    static Bitmap load(Context c) {
        File f = file(c);
        if (!f.exists() || f.length() == 0) return null;
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(f.getAbsolutePath(), o);
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
