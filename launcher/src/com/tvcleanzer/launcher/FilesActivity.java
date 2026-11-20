package com.tvcleanzer.launcher;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Pictures from a USB stick or the TV's own memory: wallpaper or photo-frame photos chosen
 * with the remote. TVs without developer mode never meet the phone app, and a flash drive is
 * how their owners bring photos (the phone sends them over ADB elsewhere).
 */
public class FilesActivity extends Activity {
    static final String MODE = "mode", WALLPAPER = "wallpaper", PHOTOS = "photos";
    private static final int MAX_SIDE = 1920;

    private Prefs prefs;
    private boolean wallpaper;
    private LinearLayout list;
    private TextView status;
    /** null: the list of drives. */
    private File dir;
    private final List<File> roots = new ArrayList<>();
    private boolean busy;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        wallpaper = WALLPAPER.equals(getIntent().getStringExtra(MODE));
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackground(Ui.background(prefs.skin()));
        int pad = Math.round(getResources().getDisplayMetrics().widthPixels * 0.05f);
        root.setPadding(pad, pad, pad, pad);
        TextView title = Ui.text(this, 34, 0xFFFFFFFF, "sans-serif-medium");
        title.setText(wallpaper ? T.t("Обои с флешки или памяти ТВ") : T.t("Фото с флешки или памяти ТВ"));
        root.addView(title);
        status = Ui.text(this, 16, 0x99FFFFFF, "sans-serif");
        status.setSingleLine(false);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-1, -2);
        slp.topMargin = Ui.dp(this, 8);
        slp.bottomMargin = Ui.dp(this, 20);
        root.addView(status, slp);
        ScrollView sv = new ScrollView(this);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        sv.addView(list);
        root.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));
        setContentView(root);

        if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(permission()) != PackageManager.PERMISSION_GRANTED) {
            status.setText(T.t("Разрешите лаунчеру доступ к фото — телевизор спросит."));
            requestPermissions(new String[]{permission()}, 1);
        } else {
            showRoots();
        }
    }

    private static String permission() {
        return Build.VERSION.SDK_INT >= 33 ? "android.permission.READ_MEDIA_IMAGES" : Manifest.permission.READ_EXTERNAL_STORAGE;
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) showRoots();
        else status.setText(T.t("Без доступа к фото лаунчер их не видит. Разрешение можно дать в настройках телевизора → Приложения."));
    }

    /** The TV's memory and every mounted USB drive / card. */
    private void showRoots() {
        dir = null;
        roots.clear();
        Map<String, File> found = new LinkedHashMap<>();
        File main = Environment.getExternalStorageDirectory();
        if (main != null) found.put(main.getAbsolutePath(), main);
        try {
            for (File f : getExternalFilesDirs(null)) {
                if (f == null) continue;
                String p = f.getAbsolutePath();
                int i = p.indexOf("/Android/data/");
                if (i > 0) found.put(p.substring(0, i), new File(p.substring(0, i)));
            }
        } catch (Throwable ignored) {}
        for (String base : new String[]{"/storage", "/mnt/usb", "/mnt/media_rw"}) {
            File[] fs = new File(base).listFiles();
            if (fs == null) continue;
            for (File f : fs) {
                String n = f.getName();
                if (n.equals("emulated") || n.equals("self") || n.startsWith(".") || !f.isDirectory() || !f.canRead()) continue;
                found.put(f.getAbsolutePath(), f);
            }
        }
        roots.addAll(found.values());
        list.removeAllViews();
        status.setText(wallpaper ? T.t("Выберите фото для фона главного экрана.")
                : T.f("Фото для фоторамки и заставки (до {0}). Сейчас: {1}.", Photos.MAX, Photos.count(this)));
        if (roots.isEmpty()) {
            status.setText(T.t("Не видно ни памяти, ни флешки. Вставьте флешку с фото и откройте снова."));
            return;
        }
        for (File r : roots) {
            String name = main != null && r.getAbsolutePath().equals(main.getAbsolutePath())
                    ? T.t("Память телевизора") : T.f("Флешка {0}", r.getName());
            row(name, "›", () -> show(r));
        }
        list.getChildAt(0).requestFocus();
    }

    private static boolean isImage(File f) {
        String n = f.getName().toLowerCase(Locale.ROOT);
        return f.isFile() && (n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png") || n.endsWith(".webp"));
    }

    private void show(File d) {
        dir = d;
        list.removeAllViews();
        File[] fs = d.listFiles();
        List<File> dirs = new ArrayList<>(), images = new ArrayList<>();
        if (fs != null) {
            Arrays.sort(fs, (a, b) -> a.getName().compareToIgnoreCase(b.getName()));
            for (File f : fs) {
                if (f.getName().startsWith(".")) continue;
                if (f.isDirectory()) dirs.add(f);
                else if (isImage(f)) images.add(f);
            }
        }
        status.setText(d.getAbsolutePath());
        row(T.t("Назад"), "‹", this::up);
        if (!wallpaper && !images.isEmpty()) {
            row(T.f("Добавить все фото отсюда ({0})", images.size()), "", () -> addPhotos(images));
        }
        for (File f : dirs) row(f.getName(), "›", () -> show(f));
        for (File f : images) {
            row(f.getName(), wallpaper ? T.t("Поставить") : T.t("Добавить"), () -> {
                if (wallpaper) setWallpaper(f); else addPhotos(java.util.Collections.singletonList(f));
            });
        }
        if (dirs.isEmpty() && images.isEmpty()) status.setText(d.getAbsolutePath() + "\n" + T.t("Здесь нет фото."));
        list.getChildAt(list.getChildCount() > 1 ? 1 : 0).requestFocus();
    }

    private void up() {
        if (dir == null) { finish(); return; }
        for (File r : roots) if (r.getAbsolutePath().equals(dir.getAbsolutePath())) { showRoots(); return; }
        File p = dir.getParentFile();
        if (p == null || !p.canRead()) showRoots(); else show(p);
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && dir != null) {
            if (!busy) up();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    // ── Copying (scaled for the TV, turned the right way up) ──────────────

    private void setWallpaper(File f) {
        if (busy) return;
        busy = true;
        status.setText(T.t("Ставим обои…"));
        new Thread(() -> {
            boolean ok = copyScaled(f, Wallpaper.internal(this));
            runOnUiThread(() -> {
                busy = false;
                if (ok) {
                    prefs.bumpWallpaper();
                    Toast.makeText(this, T.t("Обои поставлены"), Toast.LENGTH_SHORT).show();
                    finish();
                } else {
                    status.setText(T.t("Не получилось открыть это фото."));
                }
            });
        }).start();
    }

    private void addPhotos(List<File> files) {
        if (busy) return;
        int room = Photos.MAX - Photos.count(this);
        if (room <= 0) {
            Toast.makeText(this, T.f("В фоторамке уже {0} фото — сначала уберите лишние.", Photos.MAX), Toast.LENGTH_LONG).show();
            return;
        }
        busy = true;
        final List<File> take = files.subList(0, Math.min(room, files.size()));
        new Thread(() -> {
            int done = 0;
            for (int i = 0; i < take.size(); i++) {
                final int n = i + 1;
                runOnUiThread(() -> status.setText(T.f("Добавляем фото: {0} из {1}…", n, take.size())));
                if (copyScaled(take.get(i), Photos.newFile(this))) done++;
            }
            final int added = done;
            runOnUiThread(() -> {
                busy = false;
                prefs.bumpPhotos();
                Toast.makeText(this, T.f("Добавлено фото: {0}", added), Toast.LENGTH_SHORT).show();
                if (dir != null) show(dir);
            });
        }).start();
    }

    /** Decodes [src] at most MAX_SIDE on its long side, applies the camera's rotation, saves JPEG. */
    static boolean copyScaled(File src, File dst) {
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(src.getAbsolutePath(), o);
            if (o.outWidth <= 0 || o.outHeight <= 0) return false;
            int sample = 1;
            while (Math.max(o.outWidth, o.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2;
            BitmapFactory.Options d = new BitmapFactory.Options();
            d.inSampleSize = sample;
            Bitmap bm = BitmapFactory.decodeFile(src.getAbsolutePath(), d);
            if (bm == null) return false;
            float k = Math.min(1f, MAX_SIDE / (float) Math.max(bm.getWidth(), bm.getHeight()));
            Matrix m = new Matrix();
            if (k < 1f) m.postScale(k, k);
            int deg = rotation(src);
            if (deg != 0) m.postRotate(deg);
            if (!m.isIdentity()) {
                Bitmap t = Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
                if (t != bm) bm.recycle();
                bm = t;
            }
            File tmp = new File(dst.getAbsolutePath() + ".part");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                bm.compress(Bitmap.CompressFormat.JPEG, 90, out);
            }
            bm.recycle();
            return tmp.renameTo(dst) || (dst.delete() && tmp.renameTo(dst));
        } catch (Throwable t) {
            return false;
        }
    }

    private static int rotation(File f) {
        try {
            int o = new android.media.ExifInterface(f.getAbsolutePath())
                    .getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL);
            if (o == android.media.ExifInterface.ORIENTATION_ROTATE_90) return 90;
            if (o == android.media.ExifInterface.ORIENTATION_ROTATE_180) return 180;
            if (o == android.media.ExifInterface.ORIENTATION_ROTATE_270) return 270;
        } catch (Throwable ignored) {}
        return 0;
    }

    private void row(String name, String value, Runnable action) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        int ph = Ui.dp(this, 22), pv = Ui.dp(this, 14);
        row.setPadding(ph, pv, ph, pv);
        row.setFocusable(true);
        row.setClickable(true);
        float radius = Ui.dp(this, 14);
        row.setBackground(Ui.round(0x14FFFFFF, radius));
        TextView n = Ui.text(this, 19, 0xFFFFFFFF, "sans-serif-medium");
        n.setText(name);
        n.setSingleLine(true);
        n.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        TextView v = Ui.text(this, 17, 0x99FFFFFF, "sans-serif");
        v.setText(value);
        row.addView(n, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(v);
        row.setOnFocusChangeListener((x, has) -> {
            x.setBackground(Ui.round(has ? 0xFFFFFFFF : 0x14FFFFFF, radius));
            n.setTextColor(has ? 0xFF111111 : 0xFFFFFFFF);
            v.setTextColor(has ? 0xFF333333 : 0x99FFFFFF);
        });
        row.setOnClickListener(x -> action.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = Ui.dp(this, 8);
        list.addView(row, lp);
    }
}
