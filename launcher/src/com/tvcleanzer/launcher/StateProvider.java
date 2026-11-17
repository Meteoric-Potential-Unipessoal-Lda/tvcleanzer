package com.tvcleanzer.launcher;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;
import java.util.List;
import java.util.Set;

/**
 * State for the TVCleanzer phone app, over ADB:
 *   content query --uri content://com.tvcleanzer.launcher.state/apps
 *   content query --uri content://com.tvcleanzer.launcher.state/settings
 *   content write --uri content://com.tvcleanzer.launcher.state/wallpaper < photo.jpg
 * Protected by android.permission.DUMP: ADB shell has it, ordinary apps don't.
 */
public class StateProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        if (getContext() == null) return null;
        Prefs p = new Prefs(getContext());
        String path = uri.getLastPathSegment();
        if ("settings".equals(path)) {
            MatrixCursor c = new MatrixCursor(new String[]{"key", "value"});
            c.addRow(new Object[]{"skin", p.skin().id});
            c.addRow(new Object[]{"kids", p.kids() ? 1 : 0});
            c.addRow(new Object[]{"pin", p.hasPin() ? 1 : 0});
            c.addRow(new Object[]{"wallpaper", Wallpaper.exists(getContext()) ? 1 : 0});
            c.addRow(new Object[]{"version", version()});
            c.addRow(new Object[]{"anim", p.anim()});
            c.addRow(new Object[]{"ringAccent", p.ringAccent() ? 1 : 0});
            c.addRow(new Object[]{"tiles", p.tileSize()});
            c.addRow(new Object[]{"wallDim", p.wallDim()});
            c.addRow(new Object[]{"ambient", p.ambient() ? 1 : 0});
            c.addRow(new Object[]{"clock24", p.clock24() ? 1 : 0});
            c.addRow(new Object[]{"labels", p.labelsAlways() ? 1 : 0});
            c.addRow(new Object[]{"inputs", p.inputsPos()});
            c.addRow(new Object[]{"favCols", p.favCols()});
            c.addRow(new Object[]{"style", p.style()});
            c.addRow(new Object[]{"clockPos", p.clockPos()});
            c.addRow(new Object[]{"clockSize", p.clockSize()});
            c.addRow(new Object[]{"clockFont", p.clockFont()});
            c.addRow(new Object[]{"weatherCity", p.hasWeather() ? p.weatherCity() : "-"});
            c.addRow(new Object[]{"lat", p.weatherLat()});
            c.addRow(new Object[]{"lon", p.weatherLon()});
            c.addRow(new Object[]{"weatherErr", p.weatherError().isEmpty() ? "-" : p.weatherError()});
            c.addRow(new Object[]{"weatherAt", p.weatherTs()});
            c.addRow(new Object[]{"autostart", p.autostart().isEmpty() ? "-" : p.autostart()});
            c.addRow(new Object[]{"photos", Photos.count(getContext())});
            c.addRow(new Object[]{"photoSec", p.photoSec()});
            c.addRow(new Object[]{"homePhotos", p.homePhotos() ? 1 : 0});
            c.addRow(new Object[]{"splash", p.splash() ? 1 : 0});
            c.addRow(new Object[]{"appsBelow", p.appsBelow() ? 1 : 0});
            c.addRow(new Object[]{"favBottom", p.favBottom() ? 1 : 0});
            c.addRow(new Object[]{"shelf", p.shelf()});
            c.addRow(new Object[]{"prevDream", p.prevDream().isEmpty() ? "-" : p.prevDream()});
            return c;
        }
        // apps: label last, so commas in names don't break parsing on the phone
        MatrixCursor c = new MatrixCursor(new String[]{"pkg", "fav", "hidden", "kids", "label"});
        List<String> favs = p.favorites();
        Set<String> hidden = p.hidden();
        Set<String> kids = p.kidsApps();
        for (AppEntry a : AppEntry.loadAll(getContext())) {
            c.addRow(new Object[]{a.pkg, favs.indexOf(a.pkg), hidden.contains(a.pkg) ? 1 : 0,
                    kids.contains(a.pkg) ? 1 : 0, a.label.replace('\n', ' ')});
        }
        return c;
    }

    /** The phone streams a new background photo here ("w" only). */
    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String seg = uri.getLastPathSegment();
        if (getContext() == null || !mode.contains("w") || !("wallpaper".equals(seg) || "photo".equals(seg))) {
            throw new FileNotFoundException(uri.toString());
        }
        // "photo": one more picture for the photo frame (ConfigReceiver --es photos added trims to MAX)
        File f = "photo".equals(seg) ? Photos.newFile(getContext()) : Wallpaper.internal(getContext());
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_WRITE_ONLY
                | ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_TRUNCATE);
    }

    private int version() {
        try {
            return getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0).versionCode;
        } catch (Exception e) {
            return 0;
        }
    }

    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int delete(Uri uri, String s, String[] a) { return 0; }
    @Override public int update(Uri uri, ContentValues v, String s, String[] a) { return 0; }
}
