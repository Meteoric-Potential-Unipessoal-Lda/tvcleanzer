package com.tvcleanzer.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.text.InputFilter;
import android.text.InputType;
import android.view.WindowManager;
import android.widget.EditText;

/** PIN prompt for the kids mode (number pad, 4–8 digits). */
final class Pin {
    interface Callback { void onPin(String pin); }

    private Pin() {}

    static void ask(Activity a, String title, Callback cb) {
        final EditText e = new EditText(a);
        e.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        e.setFilters(new InputFilter[]{new InputFilter.LengthFilter(8)});
        e.setTextSize(28);
        e.setLetterSpacing(0.3f);
        int p = Ui.dp(a, 20);
        e.setPadding(p, p / 2, p, p / 2);
        AlertDialog d = new AlertDialog.Builder(a, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(title)
                .setView(e)
                .setPositiveButton("OK", (dlg, w) -> cb.onPin(e.getText().toString().trim()))
                .setNegativeButton("Отмена", null)
                .create();
        if (d.getWindow() != null) {
            d.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE);
        }
        d.show();
        e.requestFocus();
    }

    static boolean valid(String pin) { return pin != null && pin.matches("\\d{4,8}"); }
}
