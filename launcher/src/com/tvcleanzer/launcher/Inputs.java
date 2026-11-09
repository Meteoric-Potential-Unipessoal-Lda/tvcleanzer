package com.tvcleanzer.launcher;

import android.content.Context;
import android.content.Intent;
import android.media.tv.TvContract;
import android.media.tv.TvInputInfo;
import android.media.tv.TvInputManager;
import android.os.Build;

import java.util.ArrayList;
import java.util.List;

/** TV inputs (HDMI, AV…) from the Android TV Input Framework. */
final class Inputs {
    static final class Item {
        final String id, label;
        Item(String id, String label) { this.id = id; this.label = label; }
    }

    private Inputs() {}

    static List<Item> load(Context c) {
        List<Item> out = new ArrayList<>();
        try {
            TvInputManager tim = (TvInputManager) c.getSystemService(Context.TV_INPUT_SERVICE);
            if (tim == null) return out;
            for (TvInputInfo info : tim.getTvInputList()) {
                if (!info.isPassthroughInput()) continue; // HDMI/AV, not tuners or apps
                if (info.isHidden(c)) continue;
                CharSequence l = null;
                if (Build.VERSION.SDK_INT >= 24) l = info.loadCustomLabel(c);
                if (l == null || l.length() == 0) l = info.loadLabel(c);
                out.add(new Item(info.getId(), l == null ? "Вход" : l.toString()));
            }
        } catch (Throwable ignored) {}
        return out;
    }

    static Intent intent(Item i) {
        return new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(i.id))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    }
}
