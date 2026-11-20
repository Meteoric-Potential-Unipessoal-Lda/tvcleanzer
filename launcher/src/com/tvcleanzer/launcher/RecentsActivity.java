package com.tvcleanzer.launcher;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.usage.UsageStats;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * «Запущенные»: our own recent-apps row, for TVs whose firmware has no recents screen (most
 * Android TV ≤ 11 do nothing on the Recents key). Apps by last use, from usage stats — the
 * phone app grants us that access over ADB (`appops set … GET_USAGE_STATS allow`).
 * OK opens an app, Menu (or a long OK) closes it, «Закрыть все» frees memory; Back leaves.
 */
public class RecentsActivity extends Activity {
    private static final int MAX = 12;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private LinearLayout row;
    private TextView note;

    /** Apps the TV owner used lately, most recent first; empty without usage access. */
    static List<AppEntry> recent(Context c) {
        List<AppEntry> out = new ArrayList<>();
        if (Build.VERSION.SDK_INT < 22) return out;
        try {
            UsageStatsManager usm = (UsageStatsManager) c.getSystemService(Context.USAGE_STATS_SERVICE);
            long now = System.currentTimeMillis();
            List<UsageStats> stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, now - 3L * 24 * 3600_000, now);
            if (stats == null || stats.isEmpty()) return out;
            Map<String, Long> last = new HashMap<>();
            for (UsageStats s : stats) {
                if (s.getLastTimeUsed() <= 0 || s.getTotalTimeInForeground() <= 0) continue;
                Long old = last.get(s.getPackageName());
                if (old == null || s.getLastTimeUsed() > old) last.put(s.getPackageName(), s.getLastTimeUsed());
            }
            Map<String, AppEntry> apps = new HashMap<>();
            for (AppEntry a : AppEntry.loadAll(c)) if (!apps.containsKey(a.pkg)) apps.put(a.pkg, a);
            List<String> pkgs = new ArrayList<>(last.keySet());
            Collections.sort(pkgs, (a, b) -> Long.compare(last.get(b), last.get(a)));
            for (String p : pkgs) {
                AppEntry a = apps.get(p);
                if (a == null || p.equals(c.getPackageName())) continue;
                out.add(a);
                if (out.size() >= MAX) break;
            }
        } catch (Throwable ignored) {}
        return out;
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xE6080B12);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = Ui.dp(this, 48);
        col.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(T.t("Недавние приложения"));
        title.setTextColor(0xFFFFFFFF);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        col.addView(title);

        note = new TextView(this);
        note.setTextColor(0x99FFFFFF);
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        note.setText(T.t("ОК — открыть, «Меню» или долгое ОК — закрыть"));
        LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(-2, -2);
        nlp.topMargin = Ui.dp(this, 6);
        nlp.bottomMargin = Ui.dp(this, 28);
        col.addView(note, nlp);

        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.setClipToPadding(false);
        row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        hs.addView(row);
        col.addView(hs, new LinearLayout.LayoutParams(-2, -2));

        TextView all = new TextView(this);
        all.setText(T.t("Закрыть все"));
        all.setTextColor(0xFFFFFFFF);
        all.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        int ph = Ui.dp(this, 22), pv = Ui.dp(this, 10);
        all.setPadding(ph, pv, ph, pv);
        all.setFocusable(true);
        all.setBackground(Ui.round(0x33FFFFFF, Ui.dp(this, 22)));
        all.setOnFocusChangeListener((v, f) -> {
            v.setBackground(Ui.round(f ? 0xFFFFFFFF : 0x33FFFFFF, Ui.dp(this, 22)));
            ((TextView) v).setTextColor(f ? 0xFF000000 : 0xFFFFFFFF);
        });
        all.setOnClickListener(v -> {
            note.setText(T.t("Закрываем…"));
            new Thread(() -> {
                long mb = Memory.free(this);
                ui.post(() -> {
                    android.widget.Toast.makeText(this, mb > 0 ? T.f("Освобождено {0} МБ", mb) : T.t("Лишнего в памяти нет"),
                            android.widget.Toast.LENGTH_SHORT).show();
                    finish();
                });
            }).start();
        });
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(-2, -2);
        alp.topMargin = Ui.dp(this, 32);
        col.addView(all, alp);

        root.addView(col, new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER));
        setContentView(root);

        new Thread(() -> {
            List<AppEntry> list = recent(this);
            ui.post(() -> fill(list));
        }).start();
    }

    private void fill(List<AppEntry> list) {
        if (isFinishing()) return;
        if (list.isEmpty()) {
            note.setText(T.t("Список недоступен: подключите телефон с TVCleanzer к телевизору один раз, и он откроет доступ."));
            return;
        }
        PackageManager pm = getPackageManager();
        int w = Ui.dp(this, 168), h = Ui.dp(this, 94), gap = Ui.dp(this, 14);
        for (AppEntry a : list) {
            LinearLayout card = new LinearLayout(this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setFocusable(true);
            int p = Ui.dp(this, 6);
            card.setPadding(p, p, p, p);
            card.setBackground(Ui.round(0x00000000, Ui.dp(this, 16)));
            ImageView iv = new ImageView(this);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            Drawable icon = IconArt.icon(pm, a);
            Bitmap art = IconArt.tile(icon, w, h);
            if (art != null) iv.setImageBitmap(art); else iv.setImageDrawable(icon);
            iv.setBackground(Ui.round(0xFF1E2430, Ui.dp(this, 12)));
            iv.setClipToOutline(Build.VERSION.SDK_INT >= 21);
            card.addView(iv, new LinearLayout.LayoutParams(w, h));
            TextView t = new TextView(this);
            t.setText(a.label);
            t.setTextColor(0xCCFFFFFF);
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            t.setSingleLine(true);
            t.setEllipsize(android.text.TextUtils.TruncateAt.END);
            t.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(w, -2);
            tlp.topMargin = Ui.dp(this, 8);
            card.addView(t, tlp);
            card.setOnFocusChangeListener((v, f) -> {
                v.setBackground(Ui.round(f ? 0x40FFFFFF : 0x00000000, Ui.dp(this, 16)));
                v.animate().scaleX(f ? 1.06f : 1f).scaleY(f ? 1.06f : 1f).setDuration(120).start();
            });
            card.setOnClickListener(v -> {
                try {
                    startActivity(a.launchIntent());
                } catch (Throwable ignored) {}
                finish();
            });
            card.setOnLongClickListener(v -> { close(card, a); return true; });
            card.setOnKeyListener((v, code, e) -> {
                if (code == KeyEvent.KEYCODE_MENU && e.getAction() == KeyEvent.ACTION_UP) { close(card, a); return true; }
                return false;
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            lp.rightMargin = gap;
            row.addView(card, lp);
        }
        row.getChildAt(0).requestFocus();
    }

    /** Closes one app (background processes; the app goes when it is not on screen). */
    private void close(View card, AppEntry a) {
        try {
            ((ActivityManager) getSystemService(Context.ACTIVITY_SERVICE)).killBackgroundProcesses(a.pkg);
        } catch (Throwable ignored) {}
        int i = row.indexOfChild(card);
        row.removeView(card);
        if (row.getChildCount() == 0) { finish(); return; }
        row.getChildAt(Math.min(i, row.getChildCount() - 1)).requestFocus();
    }
}
