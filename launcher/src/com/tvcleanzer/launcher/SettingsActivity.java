package com.tvcleanzer.launcher;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.HashSet;

/** Launcher settings: theme, clock, labels, hidden apps, favourites. */
public class SettingsActivity extends Activity {
    private Prefs prefs;
    private LinearLayout root;
    private LinearLayout list;
    private int focusIndex;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.HORIZONTAL);
        setContentView(root);
        build();
    }

    private void build() {
        Skin skin = prefs.skin();
        root.removeAllViews();
        root.setBackground(Ui.background(skin));
        int screenW = getResources().getDisplayMetrics().widthPixels;
        int pad = Math.round(screenW * 0.05f);
        root.setPadding(pad, pad, pad, pad);

        // Left: title
        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        left.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = Ui.text(this, 40, 0xFFFFFFFF, "sans-serif-medium");
        title.setText("Настройки");
        TextView sub = Ui.text(this, 16, 0x99FFFFFF, "sans-serif");
        sub.setSingleLine(false);
        sub.setText("Тему и другие параметры можно менять\nи с телефона в приложении TVCleanzer.");
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(this, 12);
        left.addView(title);
        left.addView(sub, slp);
        root.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f));

        // Right: rows
        ScrollView sv = new ScrollView(this);
        sv.setClipChildren(false);
        sv.setClipToPadding(false);
        sv.setVerticalScrollBarEnabled(false);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setClipChildren(false);
        list.setPadding(Ui.dp(this, 12), 0, Ui.dp(this, 12), 0);
        sv.addView(list);
        root.addView(sv, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.2f));

        int hidden = prefs.hidden().size();
        addRow(skin, "Тема", skin.name, () -> prefs.setSkin(skin.next()));
        addRow(skin, "Часы", prefs.clock24() ? "24 часа" : "12 часов",
                () -> prefs.setClock24(!prefs.clock24()));
        addRow(skin, "Названия приложений", prefs.labelsAlways() ? "Всегда" : "При наведении",
                () -> prefs.setLabelsAlways(!prefs.labelsAlways()));
        addRow(skin, "Скрытые приложения", hidden == 0 ? "Нет" : "Показать все (" + hidden + ")", () -> {
            if (prefs.hidden().isEmpty()) return;
            prefs.setHidden(new HashSet<String>());
            Toast.makeText(this, "Все приложения снова на главном экране", Toast.LENGTH_SHORT).show();
        });
        addRow(skin, "Детский режим", prefs.kids() ? "Включён" : (prefs.hasPin() ? "Выключен" : "Настроить"),
                this::kidsMode);
        if (prefs.hasPin()) addRow(skin, "PIN детского режима", "Сменить", this::changePin);
        boolean hasWall = Wallpaper.file(this).exists();
        addRow(skin, "Обои", hasWall ? "Своё фото · убрать" : "Ставятся с телефона", () -> {
            if (!Wallpaper.file(this).exists()) return;
            //noinspection ResultOfMethodCallIgnored
            Wallpaper.file(this).delete();
            prefs.bumpWallpaper();
            Toast.makeText(this, "Обои убраны", Toast.LENGTH_SHORT).show();
        });
        addRow(skin, "Избранное", "Сбросить", () -> {
            prefs.resetFavorites();
            Toast.makeText(this, "Избранное сброшено", Toast.LENGTH_SHORT).show();
        });
        addRow(skin, "Настройки телевизора", "Открыть", () -> {
            try { startActivity(new Intent(Settings.ACTION_SETTINGS)); } catch (Exception ignored) {}
        });
        addRow(skin, "О лаунчере", "TVCleanzer Launcher " + version(), null);

        View v = list.getChildAt(Math.min(focusIndex, list.getChildCount() - 1));
        if (v != null) v.requestFocus();
    }

    // ── Kids mode ─────────────────────────────────────────────────────────

    private void kidsMode() {
        if (prefs.kids()) {
            Pin.ask(this, "PIN, чтобы выключить детский режим", pin -> {
                if (prefs.checkPin(pin)) { prefs.setKids(false); build(); }
                else Toast.makeText(this, "Неверный PIN", Toast.LENGTH_SHORT).show();
            });
        } else if (!prefs.hasPin()) {
            Pin.ask(this, "Придумайте PIN (4–8 цифр)", pin -> {
                if (!Pin.valid(pin)) {
                    Toast.makeText(this, "Нужно от 4 до 8 цифр", Toast.LENGTH_SHORT).show();
                    return;
                }
                prefs.setPin(pin);
                chooseKidsApps();
            });
        } else {
            Pin.ask(this, "Введите PIN", pin -> {
                if (prefs.checkPin(pin)) chooseKidsApps();
                else Toast.makeText(this, "Неверный PIN", Toast.LENGTH_SHORT).show();
            });
        }
    }

    private void chooseKidsApps() {
        final java.util.List<AppEntry> all = AppEntry.loadAll(this);
        final java.util.Set<String> chosen = prefs.kidsApps();
        String[] names = new String[all.size()];
        boolean[] checked = new boolean[all.size()];
        for (int i = 0; i < all.size(); i++) {
            names[i] = all.get(i).label;
            checked[i] = chosen.contains(all.get(i).pkg);
        }
        new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle("Что можно детям")
                .setMultiChoiceItems(names, checked, (d, which, on) -> {
                    if (on) chosen.add(all.get(which).pkg); else chosen.remove(all.get(which).pkg);
                })
                .setPositiveButton("Включить детский режим", (d, w) -> {
                    prefs.setKidsApps(chosen);
                    prefs.setKids(true);
                    finish(); // straight to the kids home screen
                })
                .setNegativeButton("Отмена", null)
                .show();
    }

    private void changePin() {
        Pin.ask(this, "Текущий PIN", old -> {
            if (!prefs.checkPin(old)) {
                Toast.makeText(this, "Неверный PIN", Toast.LENGTH_SHORT).show();
                return;
            }
            Pin.ask(this, "Новый PIN (4–8 цифр)", pin -> {
                if (Pin.valid(pin)) {
                    prefs.setPin(pin);
                    Toast.makeText(this, "PIN изменён", Toast.LENGTH_SHORT).show();
                } else {
                    Toast.makeText(this, "Нужно от 4 до 8 цифр", Toast.LENGTH_SHORT).show();
                }
            });
        });
    }

    private String version() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "";
        }
    }

    private void addRow(Skin skin, String name, String value, Runnable action) {
        final int index = list.getChildCount();
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        int ph = Ui.dp(this, 22), pv = Ui.dp(this, 16);
        row.setPadding(ph, pv, ph, pv);
        row.setFocusable(true);
        row.setClickable(true);
        float radius = Ui.dp(this, 14);
        row.setBackground(Ui.round(0x14FFFFFF, radius));

        TextView n = Ui.text(this, 19, 0xFFFFFFFF, "sans-serif-medium");
        n.setText(name);
        TextView val = Ui.text(this, 17, 0x99FFFFFF, "sans-serif");
        val.setText(value);
        row.addView(n, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(val);

        row.setOnFocusChangeListener((v, has) -> {
            v.setBackground(Ui.round(has ? 0xFFFFFFFF : 0x14FFFFFF, radius));
            n.setTextColor(has ? 0xFF111111 : 0xFFFFFFFF);
            val.setTextColor(has ? 0xFF333333 : 0x99FFFFFF);
            v.animate().scaleX(has ? 1.03f : 1f).scaleY(has ? 1.03f : 1f).setDuration(150).start();
        });
        if (action != null) {
            row.setOnClickListener(v -> {
                focusIndex = index;
                action.run();
                build(); // show new values (and new theme colours)
            });
        }
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = index == 0 ? 0 : Ui.dp(this, 10);
        list.addView(row, lp);
    }
}
