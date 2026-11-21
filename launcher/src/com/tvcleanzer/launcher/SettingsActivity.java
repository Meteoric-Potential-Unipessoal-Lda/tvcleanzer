package com.tvcleanzer.launcher;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.HashSet;
import java.util.List;

/** Launcher settings: everything the phone app sets, also from the remote (TVs without developer
 *  mode never meet the phone app), plus the TV screens that do what ADB does elsewhere. */
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

        // Everything the phone app sets, here too (TVs without developer mode never see the
        // phone): grouped like a TV settings screen; OK opens a list, ◀ ▶ change on the spot.
        int hidden = prefs.hidden().size();

        addHeader(skin, T.t("Вид"));
        final String[] skinNames = new String[Skin.ALL.length];
        int skinIdx = 0;
        for (int i = 0; i < Skin.ALL.length; i++) {
            skinNames[i] = Skin.ALL[i].name;
            if (Skin.ALL[i].id.equals(skin.id)) skinIdx = i;
        }
        addChoice(skin, T.t("Тема"), skinNames, skinIdx, i -> prefs.setSkin(Skin.ALL[i]));
        addChoice(skin, T.t("Вид главного экрана"), new String[]{T.t("Плитки"), T.t("Часы и док"), T.t("Витрина")},
                prefs.style(), prefs::setStyle);
        addChoice(skin, T.t("Менять тему сама"), new String[]{T.t("Нет"), T.t("Каждый час"), T.t("Каждый день")},
                prefs.skinAuto(), prefs::setSkinAuto);
        addChoice(skin, T.t("Анимации"), new String[]{T.t("Полные"), T.t("Мягкие"), T.t("Выключены")},
                prefs.anim(), prefs::setAnim);
        addToggle(skin, T.t("Живой фон"), prefs.ambient(), T.t("Включён"), T.t("Выключен"), prefs::setAmbient);
        final int[] speeds = {0, 8, 30, 90};
        addChoice(skin, T.t("Скорость живого фона"),
                new String[]{T.t("Авто"), T.t("Быстро"), T.t("Медленно"), T.t("Очень медленно")},
                indexOf(speeds, prefs.ambientSec()), i -> prefs.setAmbientSec(speeds[i]));
        addToggle(skin, T.t("Подсветка выбора"), prefs.ringAccent(), T.t("Цвет темы"), T.t("Белая"), prefs::setRingAccent);
        addToggle(skin, T.t("Только шестерёнка вверху"), prefs.cleanBar(), T.t("Включено"), T.t("Выключено"), prefs::setCleanBar);
        if (!prefs.cleanBar()) {
            addToggle(skin, T.t("Верхняя панель"), prefs.barIcons(), T.t("Значки"), T.t("Надписи"), prefs::setBarIcons);
        }
        addToggle(skin, T.t("Названия разделов"), prefs.sectionTitles(), T.t("Показывать"), T.t("Скрыто"), prefs::setSectionTitles);
        addToggle(skin, T.t("Память на главном экране"), prefs.memPill(), T.t("Показывать"), T.t("Скрыто"), prefs::setMemPill);
        addToggle(skin, T.t("Заставка при запуске"), prefs.splash(), T.t("Логотип, пока лаунчер загружается"), T.t("Выключена"),
                prefs::setSplash);

        addHeader(skin, T.t("Плитки и приложения"));
        addChoice(skin, T.t("Размер плиток"), new String[]{T.t("Мелкие"), T.t("Обычные"), T.t("Крупные")},
                prefs.tileSize(), prefs::setTileSize);
        addChoice(skin, T.t("Иконки приложений"),
                new String[]{T.t("Авто"), T.t("Иконки"), T.t("ТВ-баннеры"), T.t("Маленькие значки")},
                prefs.icons(), prefs::setIcons);
        if (prefs.icons() != Prefs.ICONS_BANNERS) {
            addChoice(skin, T.t("Форма значков"), new String[]{T.t("Скруглённые"), T.t("Круглые")},
                    prefs.iconShape(), prefs::setIconShape);
        }
        addToggle(skin, T.t("Названия приложений"), prefs.labelsAlways(), T.t("Всегда"), T.t("При наведении"),
                prefs::setLabelsAlways);
        if (prefs.style() == Prefs.STYLE_SHOWCASE) {
            addToggle(skin, T.t("Название приложения над плитками"), prefs.heroTitle(), T.t("Показывать"), T.t("Скрыто"),
                    prefs::setHeroTitle);
        }
        final int[] favSteps = {0, 4, 5, 6};
        addChoice(skin, T.t("Избранное"),
                new String[]{T.t("Один ряд"), T.f("Сетка по {0}", 4), T.f("Сетка по {0}", 5), T.f("Сетка по {0}", 6)},
                indexOf(favSteps, prefs.favCols()), i -> prefs.setFavCols(favSteps[i]));
        if (prefs.style() == Prefs.STYLE_TILES) {
            int place = !prefs.appsBelow() ? 0 : prefs.favBottom() ? 2 : 1;
            addChoice(skin, T.t("Приложения на главном"), new String[]{T.t("Сразу под избранным"),
                    T.t("На втором экране (кнопка ▼)"), T.t("На втором экране, избранное внизу")}, place, i -> {
                prefs.setAppsBelow(i > 0);
                prefs.setFavBottom(i == 2);
            });
            addChoice(skin, T.t("Подложка избранного"), new String[]{T.t("Стекло"), T.t("Прозрачная"), T.t("Тёмная")},
                    prefs.shelf(), prefs::setShelf);
        } else if (prefs.style() == Prefs.STYLE_SHOWCASE) {
            addChoice(skin, T.t("Приложения на главном"), new String[]{T.t("Сразу под избранным"),
                    T.t("На втором экране (кнопка ▼)")}, prefs.appsBelow() ? 1 : 0, i -> {
                prefs.setAppsBelow(i == 1);
                prefs.setFavBottom(false);
            });
        }
        addChoice(skin, T.t("Источники (ТВ, HDMI)"), new String[]{T.t("Вверху"), T.t("Внизу"), T.t("Скрыты")},
                prefs.inputsPos(), prefs::setInputsPos);
        addRow(skin, T.t("Скрытые приложения"), hidden == 0 ? T.t("Нет") : T.f("Показать все ({0})", hidden), () -> {
            if (prefs.hidden().isEmpty()) return;
            prefs.setHidden(new HashSet<String>());
            Toast.makeText(this, T.t("Все приложения снова на главном экране"), Toast.LENGTH_SHORT).show();
        });
        addRow(skin, T.t("Избранное"), T.t("Сбросить"), () -> {
            prefs.resetFavorites();
            Toast.makeText(this, T.t("Избранное сброшено"), Toast.LENGTH_SHORT).show();
        });

        addHeader(skin, T.t("Часы и погода"));
        addToggle(skin, T.t("Часы"), prefs.clock24(), T.t("24 часа"), T.t("12 часов"), prefs::setClock24);
        addChoice(skin, T.t("Часы: шрифт"), Prefs.CLOCK_FONT_NAMES, prefs.clockFont(), prefs::setClockFont);
        final int[] sizes = {60, 80, 100, 120, 140, 160, 180};
        String[] sizeNames = new String[sizes.length];
        for (int i = 0; i < sizes.length; i++) sizeNames[i] = sizes[i] + "%";
        addChoice(skin, T.t("Часы: размер"), sizeNames, indexOf(sizes, prefs.clockSize()), i -> prefs.setClockSize(sizes[i]));
        if (prefs.style() == Prefs.STYLE_CLOCK) {
            addChoice(skin, T.t("Часы: положение"), new String[]{T.t("Слева"), T.t("По центру")},
                    prefs.clockPos() == Prefs.CLOCK_CENTER ? 1 : 0,
                    i -> prefs.setClockPos(i == 1 ? Prefs.CLOCK_CENTER : Prefs.CLOCK_LEFT));
        }
        String w = T.t("Выключена");
        if (prefs.hasWeather()) {
            String now = Weather.line(prefs);
            w = !prefs.weatherError().isEmpty() && prefs.weatherTs() == 0
                    ? T.f("{0}: нет связи ({1})", prefs.weatherCity(), prefs.weatherError())
                    : now != null ? now : T.f("{0}: загружается…", prefs.weatherCity());
        }
        addRow(skin, T.t("Погода"), w, this::weatherCity);

        addHeader(skin, T.t("Фон и фото"));
        boolean hasWall = Wallpaper.exists(this);
        addRow(skin, T.t("Обои"), hasWall ? T.t("Своё фото") : T.t("Тема"), () -> startActivity(
                new Intent(this, FilesActivity.class).putExtra(FilesActivity.MODE, FilesActivity.WALLPAPER)));
        if (hasWall) {
            final int[] dims = {0, 20, 40, 60, 80};
            String[] dimNames = new String[dims.length];
            for (int i = 0; i < dims.length; i++) dimNames[i] = dims[i] + "%";
            addChoice(skin, T.t("Затемнение фото"), dimNames, indexOf(dims, prefs.wallDim()), i -> prefs.setWallDim(dims[i]));
            addRow(skin, T.t("Убрать обои"), "", () -> {
                Wallpaper.delete(this);
                prefs.bumpWallpaper();
                Toast.makeText(this, T.t("Обои убраны"), Toast.LENGTH_SHORT).show();
            });
        }
        int nPhotos = Photos.count(this);
        addRow(skin, T.t("Фоторамка"), nPhotos == 0 ? T.t("Добавить фото") : T.f("Фото: {0}", nPhotos), () -> startActivity(
                new Intent(this, FilesActivity.class).putExtra(FilesActivity.MODE, FilesActivity.PHOTOS)));
        if (nPhotos > 0) {
            addToggle(skin, T.t("Фон главного экрана"), prefs.homePhotos(), T.t("Меняется по фото"), T.t("Одно фото / тема"),
                    prefs::setHomePhotos);
            final int[] secs = {10, 30, 60, 300};
            String[] secNames = {T.f("{0} с", 10), T.f("{0} с", 30), T.f("{0} мин", 1), T.f("{0} мин", 5)};
            addChoice(skin, T.t("Смена фото"), secNames, indexOf(secs, prefs.photoSec()), i -> prefs.setPhotoSec(secs[i]));
            addRow(skin, T.t("Убрать все фото"), "", () -> {
                Photos.clear(this);
                prefs.bumpPhotos();
                Toast.makeText(this, T.t("Фото убраны"), Toast.LENGTH_SHORT).show();
            });
        }

        addHeader(skin, T.t("Пульт и включение"));
        addRow(skin, T.t("Кнопки пульта"), "›", () -> startActivity(new Intent(this, KeyMapActivity.class)));
        // The Home-key service's key filter costs key repeat: held Volume moves one step (many
        // Xiaomi owners). Off = smooth volume; Home then relies on the HOME setting.
        // The owner's choice is kept apart from the phone's keyFilter (volSmooth): Google TV models
        // with their home switched off kept the filter whatever was chosen here (Xiaomi MSSP owners).
        addToggle(skin, T.t("Громкость при зажатии"), !HomeKeyService.volumeFiltered(this, prefs), T.t("Меняется плавно"), T.t("По одному шагу"), v -> {
            prefs.setVolSmooth(v);
            if (!v) prefs.setKeyFilter(true);
            HomeKeyService s = HomeKeyService.running;
            if (s != null) s.updateKeyFilter();
            if (v) Toast.makeText(this, T.t("Если «Домой» перестанет открывать лаунчер, верните «По одному шагу»"),
                    Toast.LENGTH_LONG).show();
        });
        addRow(skin, T.t("При включении ТВ"), autostartName(), this::chooseAutostart);
        addRow(skin, T.t("Детский режим"), prefs.kids() ? T.t("Включён") : (prefs.hasPin() ? T.t("Выключен") : T.t("Настроить")),
                this::kidsMode);
        if (prefs.hasPin()) addRow(skin, T.t("PIN детского режима"), T.t("Сменить"), this::changePin);

        addHeader(skin, T.t("Ночной режим"));
        addChoice(skin, T.t("Ночной режим"), new String[]{T.t("Выключен"), T.t("Всегда"), T.t("По расписанию")},
                prefs.nightMode(), i -> { prefs.setNightMode(i); night(); });
        if (prefs.nightMode() != Prefs.NIGHT_OFF) {
            addChoice(skin, T.t("Сила"), new String[]{"1", "2", "3", "4", "5"}, prefs.nightLevel() - 1,
                    i -> { prefs.setNightLevel(i + 1); night(); });
        }
        if (prefs.nightMode() == Prefs.NIGHT_SCHEDULE) {
            final int[] froms = {18 * 60, 19 * 60, 20 * 60, 21 * 60, 22 * 60, 23 * 60};
            final int[] tos = {5 * 60, 6 * 60, 7 * 60, 8 * 60, 9 * 60};
            addChoice(skin, T.t("Включать в"), hhmm(froms), indexOf(froms, prefs.nightFrom()),
                    i -> { prefs.setNightFrom(froms[i]); night(); });
            addChoice(skin, T.t("Выключать в"), hhmm(tos), indexOf(tos, prefs.nightTo()),
                    i -> { prefs.setNightTo(tos[i]); night(); });
        }
        if (prefs.nightMode() != Prefs.NIGHT_OFF && (HomeKeyService.running == null || android.os.Build.VERSION.SDK_INT < 22)) {
            addRow(skin, T.t("Ночному режиму нужна служба «Домой»"), T.t("Включить"),
                    () -> openSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS));
        }

        // What the phone app does over ADB, done in the TV's own settings instead
        addHeader(skin, T.t("Телевизор"));
        addRow(skin, T.t("Главный экран"), isDefaultHome() ? T.t("Этот лаунчер") : T.t("Выбрать этот лаунчер"),
                () -> openSettings(Settings.ACTION_HOME_SETTINGS));
        addRow(skin, T.t("Кнопка «Домой» всегда сюда"), HomeKeyService.running != null ? T.t("Включено") : T.t("Включить"),
                () -> {
                    if (HomeKeyService.running == null) {
                        Toast.makeText(this, T.t("Включите «TVCleanzer Launcher» в списке служб"), Toast.LENGTH_LONG).show();
                    }
                    openSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS);
                });
        if (android.os.Build.VERSION.SDK_INT >= 22) {
            addRow(skin, T.t("Экран «Запущенные»"), HomeKeyService.usageAccess(this) ? T.t("Есть доступ") : T.t("Дать доступ"),
                    () -> openSettings(Settings.ACTION_USAGE_ACCESS_SETTINGS));
        }
        addRow(skin, T.t("Заставка ТВ"), T.t("Открыть"), () -> openSettings(Settings.ACTION_DREAM_SETTINGS));
        addRow(skin, T.t("Настройки телевизора"), T.t("Открыть"), () -> openSettings(Settings.ACTION_SETTINGS));
        addRow(skin, T.t("О лаунчере"), "TVCleanzer Launcher " + version() + " · " + AUTHOR_LINK, this::showAuthor);

        int fi = Math.max(0, Math.min(focusIndex, list.getChildCount() - 1));
        while (fi < list.getChildCount() - 1 && !list.getChildAt(fi).isFocusable()) fi++;
        View v = list.getChildAt(fi);
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

    private View addRow(Skin skin, String name, String value, Runnable action) {
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
        // a long value no longer squeezes the name into «Заставка…» (seen on an owner's video)
        val.setSingleLine(true);
        val.setEllipsize(android.text.TextUtils.TruncateAt.END);
        val.setMaxWidth(Math.round(getResources().getDisplayMetrics().widthPixels * 0.17f));
        val.setPadding(Ui.dp(this, 12), 0, 0, 0);
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
        return row;
    }

    /** A setting with a few values (java.util.function is not on Android 5–6). */
    interface Pick { void set(int i); }
    interface Flip { void set(boolean v); }

    private static String[] hhmm(int[] minutes) {
        String[] out = new String[minutes.length];
        for (int i = 0; i < minutes.length; i++) out[i] = String.format(java.util.Locale.US, "%02d:%02d", minutes[i] / 60, minutes[i] % 60);
        return out;
    }

    /** The night veil follows the new settings at once. */
    private static void night() {
        HomeKeyService s = HomeKeyService.running;
        if (s != null) s.updateNight();
    }

    private static int indexOf(int[] values, int v) {
        for (int i = 0; i < values.length; i++) if (values[i] == v) return i;
        return 0;
    }

    /** OK: the list of values; ◀ ▶: previous / next value right on the row. */
    private void addChoice(Skin skin, String name, String[] labels, int cur, Pick pick) {
        final int c = Math.max(0, Math.min(cur, labels.length - 1));
        View row = addRow(skin, name, "‹ " + labels[c] + " ›", () -> choose(name, labels, c, pick));
        row.setOnKeyListener((v, code, e) -> {
            if (e.getAction() != KeyEvent.ACTION_DOWN) return false;
            if (code != KeyEvent.KEYCODE_DPAD_LEFT && code != KeyEvent.KEYCODE_DPAD_RIGHT) return false;
            focusIndex = list.indexOfChild(v);
            int d = code == KeyEvent.KEYCODE_DPAD_RIGHT ? 1 : -1;
            pick.set((c + d + labels.length) % labels.length);
            build();
            return true;
        });
    }

    private void addToggle(Skin skin, String name, boolean on, String onName, String offName, Flip flip) {
        addChoice(skin, name, new String[]{offName, onName}, on ? 1 : 0, i -> flip.set(i == 1));
    }

    private void choose(String title, String[] labels, int cur, Pick pick) {
        if (labels.length == 2) { // a switch: OK just flips it
            pick.set(1 - cur);
            return;
        }
        new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(title)
                .setSingleChoiceItems(labels, cur, (d, which) -> {
                    d.dismiss();
                    pick.set(which);
                    build();
                })
                .setNegativeButton(T.t("Отмена"), null)
                .show();
    }

    private void addHeader(Skin skin, String text) {
        TextView h = Ui.text(this, 15, skin.accent, "sans-serif-medium");
        h.setText(text.toUpperCase(java.util.Locale.getDefault()));
        h.setLetterSpacing(0.08f);
        h.setFocusable(false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = list.getChildCount() == 0 ? 0 : Ui.dp(this, 26);
        lp.leftMargin = Ui.dp(this, 8);
        list.addView(h, lp);
    }

    /** A TV settings screen; some firmwares have no such screen. */
    private void openSettings(String action) {
        try {
            startActivity(new Intent(action));
        } catch (Exception e) {
            Toast.makeText(this, T.t("На этом телевизоре нет такого раздела настроек"), Toast.LENGTH_LONG).show();
        }
    }

    private boolean isDefaultHome() {
        try {
            android.content.pm.ResolveInfo ri = getPackageManager().resolveActivity(
                    new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                    android.content.pm.PackageManager.MATCH_DEFAULT_ONLY);
            return ri != null && ri.activityInfo != null && getPackageName().equals(ri.activityInfo.packageName);
        } catch (Exception e) {
            return false;
        }
    }

    // ── Weather city, typed on the TV ─────────────────────────────────────

    private void weatherCity() {
        final android.widget.EditText in = new android.widget.EditText(this);
        in.setSingleLine(true);
        in.setHint(T.t("Город, например Москва"));
        in.setText(prefs.weatherCity());
        int p = Ui.dp(this, 20);
        android.widget.FrameLayout box = new android.widget.FrameLayout(this);
        box.setPadding(p, p / 2, p, 0);
        box.addView(in);
        android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("Погода"))
                .setView(box)
                .setPositiveButton(T.t("Найти"), (d, x) -> searchCity(in.getText().toString().trim()))
                .setNegativeButton(T.t("Отмена"), null);
        if (prefs.hasWeather()) {
            b.setNeutralButton(T.t("Выключить"), (d, x) -> {
                prefs.setWeatherPlace("", 0, 0);
                build();
            });
        }
        b.show();
    }

    private void searchCity(String name) {
        if (name.isEmpty()) return;
        Toast.makeText(this, T.t("Ищем город…"), Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            final List<Weather.Place> found = Weather.search(name);
            runOnUiThread(() -> {
                if (isFinishing()) return;
                if (found == null) {
                    Toast.makeText(this, T.t("Нет связи с интернетом"), Toast.LENGTH_LONG).show();
                } else if (found.isEmpty()) {
                    Toast.makeText(this, T.t("Город не найден"), Toast.LENGTH_LONG).show();
                } else {
                    String[] names = new String[found.size()];
                    for (int i = 0; i < names.length; i++) names[i] = found.get(i).label;
                    new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                            .setTitle(T.t("Какой город?"))
                            .setItems(names, (d, which) -> {
                                Weather.Place pl = found.get(which);
                                prefs.setWeatherPlace(pl.city, pl.lat, pl.lon);
                                build();
                                new Thread(() -> {
                                    Weather.refreshIfStale(prefs);
                                    runOnUiThread(() -> { if (!isFinishing()) build(); });
                                }).start();
                            })
                            .setNegativeButton(T.t("Отмена"), null)
                            .show();
                }
            });
        }).start();
    }

    // ── What opens when the TV turns on ───────────────────────────────────

    private void chooseAutostart() {
        final List<String> keys = new java.util.ArrayList<>();
        final List<String> names = new java.util.ArrayList<>();
        keys.add("");
        names.add(T.t("Главный экран"));
        for (String pkg : prefs.favorites()) {
            keys.add(pkg);
            names.add(nameOf(pkg));
        }
        int cur = Math.max(0, keys.indexOf(prefs.autostart()));
        if (keys.size() == 1) {
            Toast.makeText(this, T.t("Сначала добавьте приложения в избранное"), Toast.LENGTH_LONG).show();
            return;
        }
        new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(T.t("При включении ТВ"))
                .setSingleChoiceItems(names.toArray(new String[0]), cur, (d, which) -> {
                    d.dismiss();
                    prefs.setAutostart(keys.get(which));
                    build();
                })
                .setNegativeButton(T.t("Отмена"), null)
                .show();
    }

    private String nameOf(String pkg) {
        if (pkg.startsWith("input:")) {
            String id = pkg.substring(6);
            for (Inputs.Item it : Inputs.load(this)) if (it.id.equals(id)) return it.label;
            return T.t("Источник");
        }
        try {
            return getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(pkg, 0)).toString();
        } catch (Exception e) {
            return pkg;
        }
    }
}
