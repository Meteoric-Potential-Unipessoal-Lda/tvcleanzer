package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.media.tv.TvContract;
import android.media.tv.TvInputInfo;
import android.media.tv.TvInputManager;
import android.os.Build;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** TV inputs (HDMI, AV…) from the Android TV Input Framework, plus «ТВ»: the TV's own live TV. */
final class Inputs {
    static final class Item {
        final String id, label;
        /** Set for «ТВ» (opens the TV's live TV app); null for HDMI/AV (tuned by input id). */
        final Intent open;
        Item(String id, String label) { this(id, label, null); }
        Item(String id, String label, Intent open) { this.id = id; this.label = label; this.open = open; }
    }

    /** Live TV apps of common firmwares, tried after whatever answers "view a channel". */
    private static final String[] LIVE_TV = {
            "com.mediatek.wwtv.tvcenter", "com.google.android.tv", "com.android.tv", "com.sony.dtv.tvx",
            "org.droidtv.playtv", "com.xiaomi.mitv.tvplayer", "com.droidlogic.tvsource", "com.tcl.tv",
    };

    private Inputs() {}

    static List<Item> load(Context c) {
        List<Item> out = new ArrayList<>();
        boolean tuner = false;
        try {
            TvInputManager tim = (TvInputManager) c.getSystemService(Context.TV_INPUT_SERVICE);
            if (tim != null) {
                for (TvInputInfo info : tim.getTvInputList()) {
                    if (!info.isPassthroughInput()) {
                        if (info.getType() == TvInputInfo.TYPE_TUNER) tuner = true;
                        continue; // tuners and apps: reached through «ТВ» below
                    }
                    if (info.isHidden(c)) continue;
                    CharSequence l = null;
                    if (Build.VERSION.SDK_INT >= 24) l = info.loadCustomLabel(c);
                    if (l == null || l.length() == 0) l = info.loadLabel(c);
                    out.add(new Item(info.getId(), l == null ? T.t("Вход") : l.toString()));
                }
            }
        } catch (Throwable ignored) {}
        // «ТВ» first: owners looked for the antenna among the sources (a chat question; the
        // CVTE service-menu code is typed in the picture settings while a TV source plays).
        Item tv = tv(c, tuner);
        if (tv != null) out.add(0, tv);
        return out;
    }

    /** The app that shows live TV: whoever handles "view a channel", else a known one when
     *  the TV has a tuner. Null on boxes without either. */
    static Item tv(Context c, boolean tuner) {
        try {
            PackageManager pm = c.getPackageManager();
            Set<String> cand = new LinkedHashSet<>();
            Intent view = new Intent(Intent.ACTION_VIEW)
                    .setDataAndType(TvContract.buildChannelUri(1), TvContract.Channels.CONTENT_ITEM_TYPE);
            for (ResolveInfo ri : pm.queryIntentActivities(view, 0)) {
                if (!ri.activityInfo.packageName.equals(c.getPackageName())) cand.add(ri.activityInfo.packageName);
            }
            if (tuner || !cand.isEmpty()) for (String p : LIVE_TV) cand.add(p);
            for (String p : cand) {
                Intent i = null;
                if (Build.VERSION.SDK_INT >= 21) i = pm.getLeanbackLaunchIntentForPackage(p);
                if (i == null) i = pm.getLaunchIntentForPackage(p);
                if (i != null) return new Item("tv:" + p, T.t("ТВ"), i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            }
        } catch (Throwable ignored) {}
        return null;
    }

    static Intent intent(Item i) {
        if (i.open != null) return i.open;
        return new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(i.id))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    }
}
