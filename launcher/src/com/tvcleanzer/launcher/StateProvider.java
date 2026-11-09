package com.tvcleanzer.launcher;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;

import java.util.List;
import java.util.Set;

/**
 * Read-only state for the TVCleanzer phone app, over ADB:
 *   content query --uri content://com.tvcleanzer.launcher.state/apps
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
            c.addRow(new Object[]{"wallpaper", Wallpaper.file(getContext()).exists() ? 1 : 0});
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

    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int delete(Uri uri, String s, String[] a) { return 0; }
    @Override public int update(Uri uri, ContentValues v, String s, String[] a) { return 0; }
}
