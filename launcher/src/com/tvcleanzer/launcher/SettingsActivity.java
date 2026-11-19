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
import java.util.List;

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
        title.setText(T.t("Настройки"));
        TextView sub = Ui.text(this, 16, 0x99FFFFFF, "sans-serif");
        sub.setSingleLine(false);
        sub.setText(T.t("Тему и другие параметры можно менять\nи с телефона в приложении TVCleanzer."));
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(this, 12);
        left.addView(title);
        left.addView(sub, slp);
        if (prefs.stockOff()) {
            // Google TV Home was switched off to keep this launcher: removing the launcher in the
            // TV's own settings would leave a black screen (a Philips owner did exactly that).
            TextView warn = Ui.text(this, 16, 0xFFFFB547, "sans-serif-medium");
            warn.setSingleLine(false);
            warn.setText(T.t("Родной экран Google TV выключен, чтобы этот лаунчер оставался главным.\n"
                    + "Удаляйте лаунчер только в приложении TVCleanzer на телефоне\n"
                    + "(«Вернуть стандартный лаунчер»), не в настройках телевизора."));
            LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            wlp.topMargin = Ui.dp(this, 16);
            left.addView(warn, wlp);
        }
        left.addView(authorBlock());
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
        addRow(skin, T.t("Тема"), skin.name, () -> prefs.setSkin(skin.next()));
        addRow(skin, T.t("Часы"), prefs.clock24() ? T.t("24 часа") : T.t("12 часов"),
                () -> prefs.setClock24(!prefs.clock24()));
        addRow(skin, T.t("Названия приложений"), prefs.labelsAlways() ? T.t("Всегда") : T.t("При наведении"),
                () -> prefs.setLabelsAlways(!prefs.labelsAlways()));
        addRow(skin, T.t("Скрытые приложения"), hidden == 0 ? T.t("Нет") : T.f("Показать все ({0})", hidden), () -> {
            if (prefs.hidden().isEmpty()) return;
            prefs.setHidden(new HashSet<String>());
            Toast.makeText(this, T.t("Все приложения снова на главном экране"), Toast.LENGTH_SHORT).show();
        });
        addRow(skin, T.t("Детский режим"), prefs.kids() ? T.t("Включён") : (prefs.hasPin() ? T.t("Выключен") : T.t("Настроить")),
                this::kidsMode);
        if (prefs.hasPin()) addRow(skin, T.t("PIN детского режима"), T.t("Сменить"), this::changePin);
        String[] animNames = {T.t("Полные"), T.t("Мягкие"), T.t("Выключены")};
        addRow(skin, T.t("Анимации"), animNames[prefs.anim()], () -> prefs.setAnim((prefs.anim() + 1) % 3));
        String[] tileNames = {T.t("Мелкие"), T.t("Обычные"), T.t("Крупные")};
        addRow(skin, T.t("Размер плиток"), tileNames[prefs.tileSize()], () -> prefs.setTileSize((prefs.tileSize() + 1) % 3));
        addRow(skin, T.t("Подсветка выбора"), prefs.ringAccent() ? T.t("Цвет темы") : T.t("Белая"),
                () -> prefs.setRingAccent(!prefs.ringAccent()));
        addRow(skin, T.t("Живой фон"), prefs.ambient() ? T.t("Включён") : T.t("Выключен"), () -> prefs.setAmbient(!prefs.ambient()));
        addRow(skin, T.t("Вид главного экрана"), prefs.style() == Prefs.STYLE_CLOCK ? T.t("Часы и док") : T.t("Плитки"),
                () -> prefs.setStyle(prefs.style() == Prefs.STYLE_CLOCK ? Prefs.STYLE_TILES : Prefs.STYLE_CLOCK));
        addRow(skin, T.t("Часы: шрифт"), Prefs.CLOCK_FONT_NAMES[prefs.clockFont()],
                () -> prefs.setClockFont((prefs.clockFont() + 1) % Prefs.CLOCK_FONTS.length));
        addRow(skin, T.t("Часы: размер"), prefs.clockSize() + "%",
                () -> prefs.setClockSize(prefs.clockSize() >= 160 ? 80 : prefs.clockSize() + 20));
        if (prefs.style() == Prefs.STYLE_CLOCK) {
            addRow(skin, T.t("Часы: положение"), prefs.clockPos() == Prefs.CLOCK_CENTER ? T.t("По центру") : T.t("Слева"),
                    () -> prefs.setClockPos(prefs.clockPos() == Prefs.CLOCK_CENTER ? Prefs.CLOCK_LEFT : Prefs.CLOCK_CENTER));
        }
        String w = T.t("Город задаётся с телефона");
        if (prefs.hasWeather()) {
            String now = Weather.line(prefs);
            w = !prefs.weatherError().isEmpty() && prefs.weatherTs() == 0
                    ? T.f("{0}: нет связи ({1})", prefs.weatherCity(), prefs.weatherError())
                    : now != null ? now : T.f("{0}: загружается…", prefs.weatherCity());
        }
        addRow(skin, T.t("Погода"), w, null);
        int nPhotos = Photos.count(this);
        addRow(skin, T.t("Фоторамка"), nPhotos == 0 ? T.t("Фото добавляются с телефона") : T.f("Фото: {0}", nPhotos), null);
        if (nPhotos > 0) {
            addRow(skin, T.t("Фон главного экрана"), prefs.homePhotos() ? T.t("Меняется по фото") : T.t("Одно фото / шкурка"),
                    () -> prefs.setHomePhotos(!prefs.homePhotos()));
            final int[] secs = {10, 30, 60, 300};
            int cur = prefs.photoSec();
            addRow(skin, T.t("Смена фото"), cur >= 60 ? T.f("{0} мин", cur / 60) : T.f("{0} с", cur), () -> {
                int k = 0;
                for (int i = 0; i < secs.length; i++) if (secs[i] == prefs.photoSec()) k = i;
                prefs.setPhotoSec(secs[(k + 1) % secs.length]);
            });
        }
        addRow(skin, T.t("Заставка при запуске"), prefs.splash() ? T.t("Логотип, пока лаунчер загружается") : T.t("Выключена"),
                () -> prefs.setSplash(!prefs.splash()));
        if (prefs.style() == Prefs.STYLE_TILES) {
            // three steps: under favourites → second screen → second screen with favourites low
            String place = !prefs.appsBelow() ? T.t("Сразу под избранным")
                    : prefs.favBottom() ? T.t("На втором экране, избранное внизу") : T.t("На втором экране (кнопка ▼)");
            addRow(skin, T.t("Приложения на главном"), place, () -> {
                if (!prefs.appsBelow()) { prefs.setAppsBelow(true); prefs.setFavBottom(false); }
                else if (!prefs.favBottom()) prefs.setFavBottom(true);
                else { prefs.setAppsBelow(false); prefs.setFavBottom(false); }
            });
            final String[] shelfNames = {T.t("Стекло"), T.t("Прозрачная"), T.t("Тёмная")};
            addRow(skin, T.t("Подложка избранного"), shelfNames[prefs.shelf()],
                    () -> prefs.setShelf((prefs.shelf() + 1) % 3));
        }
        final int[] favSteps = {0, 4, 5, 6};
        int fc = prefs.favCols();
        addRow(skin, T.t("Избранное"), fc == 0 ? T.t("Один ряд") : T.f("Сетка по {0}", fc), () -> {
            int k = 0;
            for (int i = 0; i < favSteps.length; i++) if (favSteps[i] == prefs.favCols()) k = i;
            prefs.setFavCols(favSteps[(k + 1) % favSteps.length]);
        });
        String[] inputsNames = {T.t("Вверху"), T.t("Внизу"), T.t("Скрыты")};
        addRow(skin, T.t("Источники (ТВ, HDMI)"), inputsNames[prefs.inputsPos()],
                () -> prefs.setInputsPos((prefs.inputsPos() + 1) % 3));
        addRow(skin, T.t("При включении ТВ"), autostartName(),
                () -> prefs.setAutostart(nextAutostart()));
        boolean hasWall = Wallpaper.exists(this);
        if (hasWall) {
            addRow(skin, T.t("Затемнение фото"), prefs.wallDim() + "%",
                    () -> prefs.setWallDim(prefs.wallDim() >= 80 ? 0 : prefs.wallDim() + 20));
        }
        addRow(skin, T.t("Обои"), hasWall ? T.t("Своё фото · убрать") : T.t("Ставятся с телефона"), () -> {
            if (!Wallpaper.exists(this)) return;
            Wallpaper.delete(this);
            prefs.bumpWallpaper();
            Toast.makeText(this, T.t("Обои убраны"), Toast.LENGTH_SHORT).show();
        });
        addRow(skin, T.t("Избранное"), T.t("Сбросить"), () -> {
            prefs.resetFavorites();
            Toast.makeText(this, T.t("Избранное сброшено"), Toast.LENGTH_SHORT).show();
        });
        addRow(skin, T.t("Настройки телевизора"), T.t("Открыть"), () -> {
            try { startActivity(new Intent(Settings.ACTION_SETTINGS)); } catch (Exception ignored) {}
        });
        addRow(skin, T.t("О лаунчере"), "TVCleanzer Launcher " + version() + " · " + AUTHOR_LINK, this::showAuthor);

        View v = list.getChildAt(Math.min(focusIndex, list.getChildCount() - 1));
        if (v != null) v.requestFocus();
    }

    // ── Author: quietly, at the bottom of Settings ───────────────────────────

    static final String AUTHOR = T.t("Андрей Жердев");
    static final String AUTHOR_LINK = "t.me/zherdyevofficial";

    /** A small QR (opens the author's Telegram on a phone) and one muted line. */
    private View authorBlock() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.HORIZONTAL);
        box.setGravity(Gravity.CENTER_VERTICAL);
        box.setAlpha(0.55f);
        android.widget.ImageView qr = qrView(Ui.dp(this, 64));
        if (qr != null) box.addView(qr);
        TextView t = Ui.text(this, 13, 0xCCFFFFFF, "sans-serif");
        t.setSingleLine(false);
        t.setText(T.f("Автор — {0}", AUTHOR) + "\n" + AUTHOR_LINK);
        LinearLayout.LayoutParams tl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tl.leftMargin = Ui.dp(this, 12);
        box.addView(t, tl);
        LinearLayout.LayoutParams bl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        bl.topMargin = Ui.dp(this, 40);
        box.setLayoutParams(bl);
        return box;
    }

    private android.widget.ImageView qrView(int size) {
        int id = getResources().getIdentifier("author_qr", "drawable", getPackageName());
        if (id == 0) return null;
        android.widget.ImageView qr = new android.widget.ImageView(this);
        qr.setImageResource(id);
        qr.setBackground(Ui.round(0xFFFFFFFF, Ui.dp(this, 6)));
        int p = Ui.dp(this, 3);
        qr.setPadding(p, p, p, p);
        qr.setLayoutParams(new LinearLayout.LayoutParams(size, size));
        return qr;
    }

    /** "О лаунчере": a bigger QR, easy to scan from the sofa. */
    private void showAuthor() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setGravity(Gravity.CENTER_HORIZONTAL);
        int p = Ui.dp(this, 24);
        v.setPadding(p, p, p, p);
        android.widget.ImageView qr = qrView(Ui.dp(this, 180));
        if (qr != null) v.addView(qr);
        TextView t = Ui.text(this, 16, 0xFFFFFFFF, "sans-serif");
        t.setSingleLine(false);
        t.setGravity(Gravity.CENTER_HORIZONTAL);
        t.setText("TVCleanzer Launcher " + version() + "\n" + T.f("Автор — {0}", AUTHOR) + " · " + AUTHOR_LINK
                + "\n" + T.t("Наведите камеру телефона на код: откроется Telegram-канал."));
        LinearLayout.LayoutParams tl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tl.topMargin = Ui.dp(this, 14);
        v.addView(t, tl);
        new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setView(v)
                .setPositiveButton(T.t("Закрыть"), null)
                .show();
    }

    // ── Kids mode ─────────────────────────────────────────────────────────

    private void kidsMode() {
        if (prefs.kids()) {
            Pin.ask(this, T.t("PIN, чтобы выключить детский режим"), pin -> {
                if (prefs.checkPin(pin)) { prefs.setKids(false); build(); }
                else Toast.makeText(this, T.t("Неверный PIN"), Toast.LENGTH_SHORT).show();
            });
        } else if (!prefs.hasPin()) {
            Pin.ask(this, T.t("Придумайте PIN (4–8 цифр)"), pin -> {
                if (!Pin.valid(pin)) {
                    Toast.makeText(this, T.t("Нужно от 4 до 8 цифр"), Toast.LENGTH_SHORT).show();
                    return;
                }
                prefs.setPin(pin);
                chooseKidsApps();
            });
        } else {
            Pin.ask(this, T.t("Введите PIN"), pin -> {
                if (prefs.checkPin(pin)) chooseKidsApps();
                else Toast.makeText(this, T.t("Неверный PIN"), Toast.LENGTH_SHORT).show();
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
                .setTitle(T.t("Что можно детям"))
                .setMultiChoiceItems(names, checked, (d, which, on) -> {
                    if (on) chosen.add(all.get(which).pkg); else chosen.remove(all.get(which).pkg);
                })
                .setPositiveButton(T.t("Включить детский режим"), (d, w) -> {
                    prefs.setKidsApps(chosen);
                    prefs.setKids(true);
                    finish(); // straight to the kids home screen
                })
                .setNegativeButton(T.t("Отмена"), null)
                .show();
    }

    private void changePin() {
        Pin.ask(this, T.t("Текущий PIN"), old -> {
            if (!prefs.checkPin(old)) {
                Toast.makeText(this, T.t("Неверный PIN"), Toast.LENGTH_SHORT).show();
                return;
            }
            Pin.ask(this, T.t("Новый PIN (4–8 цифр)"), pin -> {
                if (Pin.valid(pin)) {
                    prefs.setPin(pin);
                    Toast.makeText(this, T.t("PIN изменён"), Toast.LENGTH_SHORT).show();
                } else {
                    Toast.makeText(this, T.t("Нужно от 4 до 8 цифр"), Toast.LENGTH_SHORT).show();
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

    /** Cycle: nothing -> each favourite -> nothing. */
    private String nextAutostart() {
        List<String> favs = prefs.favorites();
        String cur = prefs.autostart();
        int i = favs.indexOf(cur);
        if (cur.isEmpty()) return favs.isEmpty() ? "" : favs.get(0);
        return i >= 0 && i + 1 < favs.size() ? favs.get(i + 1) : "";
    }

    private String autostartName() {
        String pkg = prefs.autostart();
        if (pkg.isEmpty()) return T.t("Главный экран");
        if (pkg.startsWith("input:")) {
            String id = pkg.substring(6);
            for (Inputs.Item it : Inputs.load(this)) if (it.id.equals(id)) return T.f("Открыть {0}", it.label);
            return T.t("Источник");
        }
        try {
            return T.f("Открыть {0}", getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(pkg, 0)));
        } catch (Exception e) {
            return pkg;
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
        if (android.os.Build.VERSION.SDK_INT >= 26) row.setDefaultFocusHighlightEnabled(false);
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
