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
        /** «ТВ»: ways to land on the antenna/cable itself, tried before [open]. Launching the TV
         *  app alone shows its last source — often HDMI 1 (an owner: «выбираю ТВ — включается
         *  HDMI 1»). */
        final List<Intent> first = new ArrayList<>();
        Item(String id, String label) { this(id, label, null); }
        Item(String id, String label, Intent open) { this.id = id; this.label = label; this.open = open; }
    }

    /** Opens [i]: the tuner channel / tuner input first, the TV app as the last resort. */
    static boolean open(Context c, Item i) {
        for (Intent t : i.first) {
            try { c.startActivity(t); return true; } catch (Throwable ignored) {}
        }
        Intent std = intent(i);
        if (i.open == null) {
            PackageManager pm = c.getPackageManager();
            if (pm.queryIntentActivities(std, 0).isEmpty()) {
                // Nobody answers the standard "view an input" (TCL G10: only Google TV's home
                // could open HDMI, our tiles bounced back). Hand the same request to the TV's
                // own player by name: TCL's TVActivity takes it (VIV, Smart TV Pro, tested).
                Intent direct = directPlayer(c, std.getData());
                if (direct != null) {
                    try { c.startActivity(direct); return true; } catch (Throwable ignored) {}
                }
            }
        }
        try { c.startActivity(std); return true; } catch (Throwable e) { return false; }
    }

    /** Players that open an input when asked by name, with the passthrough URI as data. */
    private static final String[][] DIRECT = {
            {"com.tcl.tv", "com.tcl.tv.TVActivity"},
    };

    private static Intent directPlayer(Context c, android.net.Uri data) {
        PackageManager pm = c.getPackageManager();
        for (String[] d : DIRECT) {
            Intent i = new Intent(Intent.ACTION_VIEW, data)
                    .setComponent(new android.content.ComponentName(d[0], d[1]))
                    // a running player keeps its input when the request only reaches onNewIntent:
                    // start it afresh (tested: worked only after the player was closed)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            // the input id as an extra too: some builds read it from there (tested to work as well)
            String id = android.media.tv.TvContract.isChannelUriForPassthroughInput(data) && data.getPathSegments().size() > 1
                    ? data.getPathSegments().get(1) : null;
            if (id != null) {
                i.putExtra("inputId", id);
                i.putExtra("android.media.tv.extra.INPUT_ID", id);
            }
            try {
                if (pm.resolveActivity(i, 0) != null) return i;
            } catch (Throwable ignored) {}
        }
        return null;
    }

    /** The first channel of the TV's tuner (needs READ_EPG_DATA, granted by the phone app over
     *  ADB; without it the query fails and we fall back). */
    private static Intent firstChannel(Context c, String tunerId, String pkg) {
        if (tunerId == null) return null;
        android.database.Cursor cur = null;
        try {
            cur = c.getContentResolver().query(TvContract.buildChannelsUriForInput(tunerId),
                    new String[]{TvContract.Channels._ID}, TvContract.Channels.COLUMN_BROWSABLE + "=1",
                    null, null);
            if (cur == null || !cur.moveToFirst()) {
                if (cur != null) cur.close();
                cur = c.getContentResolver().query(TvContract.buildChannelsUriForInput(tunerId),
                        new String[]{TvContract.Channels._ID}, null, null, null);
            }
            if (cur == null || !cur.moveToFirst()) return null;
            Intent i = new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUri(cur.getLong(0)))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (pkg != null) i.setPackage(pkg);
            return i;
        } catch (Throwable t) {
            return null;
        } finally {
            if (cur != null) try { cur.close(); } catch (Throwable ignored) {}
        }
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
        String tunerId = null;
        try {
            TvInputManager tim = (TvInputManager) c.getSystemService(Context.TV_INPUT_SERVICE);
            if (tim != null) {
                for (TvInputInfo info : tim.getTvInputList()) {
                    if (!info.isPassthroughInput()) {
                        if (info.getType() == TvInputInfo.TYPE_TUNER) {
                            tuner = true;
                            if (tunerId == null) tunerId = info.getId();
                        }
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
        Item tv = tv(c, tuner, tunerId);
        if (tv != null) out.add(0, tv);
        return out;
    }

    /** «ТВ» with its tuner looked up again (for the remote's TV key and autostart). */
    static Item tv(Context c, boolean tuner) {
        String tunerId = null;
        try {
            TvInputManager tim = (TvInputManager) c.getSystemService(Context.TV_INPUT_SERVICE);
            if (tim != null) for (TvInputInfo info : tim.getTvInputList()) {
                if (!info.isPassthroughInput() && info.getType() == TvInputInfo.TYPE_TUNER) { tunerId = info.getId(); break; }
            }
        } catch (Throwable ignored) {}
        return tv(c, tuner || tunerId != null, tunerId);
    }

    /** The app that shows live TV: whoever handles "view a channel", else a known one when
     *  the TV has a tuner. Null on boxes without either. */
    private static Item tv(Context c, boolean tuner, String tunerId) {
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
                if (i != null) {
                    Item item = new Item("tv:" + p, T.t("ТВ"), i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    Intent ch = firstChannel(c, tunerId, p);
                    if (ch != null && !pm.queryIntentActivities(ch, 0).isEmpty()) item.first.add(ch);
                    if (tunerId != null) {
                        // the tuner as an input: MediaTek / AOSP Live TV switch the source to it
                        Intent src = new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(tunerId))
                                .setPackage(p).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        if (!pm.queryIntentActivities(src, 0).isEmpty()) item.first.add(src);
                    }
                    return item;
                }
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
