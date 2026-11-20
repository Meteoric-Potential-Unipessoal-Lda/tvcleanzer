package com.tvcleanzer.launcher;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * «Кнопки пульта»: a remote button (Netflix, Prime Video, an app key without a use) opens an
 * app of the owner's choice (a review asked for YouTube on the Netflix key). The button is
 * learned through the Home key service; buttons the firmware keeps for itself never reach it,
 * and then the screen says so. Keys of navigation, volume and power can't be taken.
 */
public class KeyMapActivity extends Activity {
    private final Handler ui = new Handler(Looper.getMainLooper());
    private Prefs prefs;
    private LinearLayout list;
    private TextView status;
    private int learned = -1;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackground(Ui.background(prefs.skin()));
        int pad = Math.round(getResources().getDisplayMetrics().widthPixels * 0.05f);
        root.setPadding(pad, pad, pad, pad);
        TextView title = Ui.text(this, 34, 0xFFFFFFFF, "sans-serif-medium");
        title.setText(T.t("Кнопки пульта"));
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
        showMappings();
    }

    @Override
    protected void onDestroy() {
        HomeKeyService.learn = null;
        HomeKeyService s = HomeKeyService.running;
        if (s != null) s.updateKeyFilter();
        super.onDestroy();
    }

    private void showMappings() {
        learned = -1;
        HomeKeyService.learn = null;
        list.removeAllViews();
        status.setText(HomeKeyService.running == null
                ? T.t("Нужна служба кнопки «Домой» TVCleanzer: включите её с телефона на вкладке «Лаунчер».")
                : T.t("Кнопка пульта может открывать любое приложение. ОК на строке — убрать назначение."));
        row(T.t("Назначить кнопку"), "+", this::learn);
        Map<Integer, String> map = prefs.keyMap();
        List<Integer> codes = new ArrayList<>(map.keySet());
        Collections.sort(codes);
        for (final int code : codes) {
            final String pkg = map.get(code);
            row(keyName(code), appName(pkg), () -> {
                prefs.removeKey(code);
                HomeKeyService s = HomeKeyService.running;
                if (s != null) s.updateKeyFilter();
                showMappings();
            });
        }
        list.getChildAt(0).requestFocus();
    }

    /** Waits for one press of the remote button to be assigned. */
    private void learn() {
        HomeKeyService s = HomeKeyService.running;
        if (s == null) { showMappings(); return; }
        list.removeAllViews();
        status.setText(T.t("Нажмите на пульте кнопку, которую хотите назначить…"));
        HomeKeyService.learn = code -> ui.post(() -> picked(code));
        s.updateKeyFilter();
        ui.postDelayed(() -> {
            if (learned < 0 && HomeKeyService.learn != null) {
                HomeKeyService.learn = null;
                status.setText(T.t("Кнопка не дошла до лаунчера: телевизор оставляет её себе. Попробуйте другую."));
                row(T.t("Назад"), "", this::showMappings);
                list.getChildAt(0).requestFocus();
            }
        }, 12_000);
    }

    private void picked(int code) {
        if (learned >= 0) return;
        if (!HomeKeyService.remappable(code)) {
            status.setText(T.f("Эту кнопку ({0}) занять нельзя: она нужна для управления. Нажмите другую.", keyName(code)));
            return; // still listening
        }
        learned = code;
        HomeKeyService.learn = null;
        status.setText(T.f("Кнопка {0}: какое приложение открывать?", keyName(code)));
        list.removeAllViews();
        List<AppEntry> apps = AppEntry.loadAll(this);
        Collections.sort(apps, (a, b) -> a.label.compareToIgnoreCase(b.label));
        for (final AppEntry a : apps) {
            if (a.pkg.equals(getPackageName())) continue;
            row(a.label, "", () -> {
                prefs.putKey(code, a.pkg);
                HomeKeyService s = HomeKeyService.running;
                if (s != null) s.updateKeyFilter();
                showMappings();
            });
        }
        if (list.getChildCount() > 0) list.getChildAt(0).requestFocus();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && (learned >= 0 || HomeKeyService.learn != null)) {
            showMappings();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private String appName(String pkg) {
        try {
            return getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(pkg, 0)).toString();
        } catch (Throwable t) {
            return pkg;
        }
    }

    static String keyName(int code) {
        String s = KeyEvent.keyCodeToString(code);
        if (s.startsWith("KEYCODE_")) s = s.substring(8);
        return s.replace('_', ' ');
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
