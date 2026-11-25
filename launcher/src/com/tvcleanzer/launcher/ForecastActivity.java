package com.tvcleanzer.launcher;

import android.app.Activity;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;

/**
 * 1.42: the forecast for the week, opened with OK on the weather on the home screen (promised
 * in a Play review, 24.11). Asked when opened (Open-Meteo, then met.no), nothing kept.
 */
public class ForecastActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private LinearLayout row;
    private TextView note;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        Prefs prefs = new Prefs(this);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xE6080B12);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = Ui.dp(this, 48);
        col.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(prefs.weatherCity().isEmpty() ? T.t("Прогноз погоды") : T.t("Прогноз погоды") + " · " + prefs.weatherCity());
        title.setTextColor(0xFFFFFFFF);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        col.addView(title);

        note = new TextView(this);
        note.setTextColor(0x99FFFFFF);
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        note.setText(T.t("Загружаем прогноз…"));
        LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(-2, -2);
        nlp.topMargin = Ui.dp(this, 8);
        nlp.bottomMargin = Ui.dp(this, 28);
        col.addView(note, nlp);

        row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER);
        col.addView(row, new LinearLayout.LayoutParams(-1, -2));

        root.addView(col, new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER));
        setContentView(root);

        if (!prefs.hasWeather()) {
            note.setText(T.t("Город для погоды не выбран"));
            return;
        }
        new Thread(() -> {
            final List<Weather.Day> days = Weather.forecast(prefs);
            main.post(() -> show(prefs, days));
        }, "tvc-forecast").start();
    }

    private void show(Prefs prefs, List<Weather.Day> days) {
        if (isFinishing()) return;
        if (days == null || days.isEmpty()) {
            note.setText(T.t("Не удалось получить прогноз. Проверьте интернет на телевизоре."));
            return;
        }
        note.setText(T.t("«Назад» — закрыть"));
        int w = getResources().getDisplayMetrics().widthPixels;
        int n = Math.min(days.size(), 7);
        int cardW = Math.min(Ui.dp(this, 150), (w - Ui.dp(this, 96)) / n - Ui.dp(this, 12));
        int icon = Math.round(cardW * 0.55f);
        SimpleDateFormat dayName = new SimpleDateFormat("EEEE", Locale.getDefault());
        SimpleDateFormat date = new SimpleDateFormat("d MMM", Locale.getDefault());
        Calendar today = Calendar.getInstance();
        for (int i = 0; i < n; i++) {
            Weather.Day d = days.get(i);
            LinearLayout card = new LinearLayout(this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setPadding(Ui.dp(this, 8), Ui.dp(this, 16), Ui.dp(this, 8), Ui.dp(this, 16));
            card.setBackground(Ui.round(i == 0 ? 0x26FFFFFF : 0x14FFFFFF, Ui.dp(this, 18)));
            card.setFocusable(true);
            card.setOnFocusChangeListener((v, has) -> v.setBackground(Ui.round(has ? 0x40FFFFFF : 0x14FFFFFF, Ui.dp(this, 18))));

            Calendar c = Calendar.getInstance();
            c.setTimeInMillis(d.dayMs);
            String name;
            if (sameDay(c, today)) name = T.t("Сегодня");
            else {
                Calendar t = (Calendar) today.clone();
                t.add(Calendar.DAY_OF_YEAR, 1);
                name = sameDay(c, t) ? T.t("Завтра") : cap(dayName.format(c.getTime()));
            }
            card.addView(text(name, 17, 0xFFFFFFFF, true));
            card.addView(text(date.format(c.getTime()), 13, 0x99FFFFFF, false));

            ImageView pic = new ImageView(this);
            pic.setScaleType(ImageView.ScaleType.FIT_CENTER);
            Drawable dr = WeatherIcons.byName(this, WeatherIcons.forCode(d.code, true), icon);
            pic.setImageDrawable(dr);
            LinearLayout.LayoutParams pl = new LinearLayout.LayoutParams(icon, icon);
            pl.topMargin = Ui.dp(this, 10);
            pl.bottomMargin = Ui.dp(this, 10);
            card.addView(pic, pl);

            card.addView(text(deg(d.max), 24, 0xFFFFFFFF, true));
            card.addView(text(deg(d.min), 17, 0x99FFFFFF, false));
            TextView sky = text(Weather.describe(d.code), 12, 0xB3FFFFFF, false);
            sky.setMaxLines(2);
            sky.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams sl = new LinearLayout.LayoutParams(-1, -2);
            sl.topMargin = Ui.dp(this, 6);
            card.addView(sky, sl);

            LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(cardW, ViewGroup.LayoutParams.WRAP_CONTENT);
            cl.leftMargin = Ui.dp(this, 6);
            cl.rightMargin = Ui.dp(this, 6);
            row.addView(card, cl);
        }
        if (row.getChildCount() > 0) row.getChildAt(0).requestFocus();
    }

    private static boolean sameDay(Calendar a, Calendar b) {
        return a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR);
    }

    private static String cap(String s) {
        return s.isEmpty() ? s : s.substring(0, 1).toUpperCase(Locale.getDefault()) + s.substring(1);
    }

    private static String deg(int t) { return (t > 0 ? "+" : "") + t + "°"; }

    private TextView text(String s, float sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextColor(color);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setSingleLine(sp > 12);
        t.setGravity(Gravity.CENTER_HORIZONTAL);
        t.setTypeface(android.graphics.Typeface.create(bold ? "sans-serif-medium" : "sans-serif", android.graphics.Typeface.NORMAL));
        return t;
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_DPAD_CENTER && e.isLongPress()) {
            finish();
            return true;
        }
        return super.onKeyDown(code, e);
    }
}
