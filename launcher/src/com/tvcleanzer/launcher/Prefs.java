package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** All launcher settings. One SharedPreferences file, read in-process. */
final class Prefs {
    static final String FILE = "launcher";
    static final String SKIN = "skin", CLOCK24 = "clock24", LABELS = "labels",
            FAVORITES = "favorites", HIDDEN = "hidden";

    final SharedPreferences sp;

    Prefs(Context c) { sp = c.getSharedPreferences(FILE, Context.MODE_PRIVATE); }

    Skin skin()              { return Skin.byId(sp.getString(SKIN, "midnight")); }
    void setSkin(Skin s)     { sp.edit().putString(SKIN, s.id).apply(); }
    boolean clock24()        { return sp.getBoolean(CLOCK24, true); }
    void setClock24(boolean v) { sp.edit().putBoolean(CLOCK24, v).apply(); }
    /** true: names always under tiles; false: only for the focused tile (like tvOS). */
    boolean labelsAlways()   { return sp.getBoolean(LABELS, false); }
    void setLabelsAlways(boolean v) { sp.edit().putBoolean(LABELS, v).apply(); }

    boolean hasFavorites()   { return sp.contains(FAVORITES); }
    List<String> favorites() {
        String raw = sp.getString(FAVORITES, "");
        List<String> out = new ArrayList<>();
        if (!TextUtils.isEmpty(raw)) out.addAll(Arrays.asList(raw.split(",")));
        return out;
    }
    void setFavorites(List<String> keys) {
        sp.edit().putString(FAVORITES, TextUtils.join(",", keys)).apply();
    }
    void resetFavorites()    { sp.edit().remove(FAVORITES).apply(); }

    Set<String> hidden()     { return new HashSet<>(sp.getStringSet(HIDDEN, new HashSet<String>())); }
    void setHidden(Set<String> keys) { sp.edit().putStringSet(HIDDEN, new HashSet<>(keys)).apply(); }
}
