package com.tvcleanzer.launcher;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Settings pushed from the TVCleanzer phone app over ADB. */
public class ConfigReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!"com.tvcleanzer.launcher.APPLY".equals(intent.getAction())) return;
        Prefs p = new Prefs(context);
        String skin = intent.getStringExtra("skin");
        if (skin != null) p.setSkin(Skin.byId(skin));
        if (intent.hasExtra("clock24")) p.setClock24(intent.getBooleanExtra("clock24", true));
        if (intent.hasExtra("labels")) p.setLabelsAlways(intent.getBooleanExtra("labels", false));
        if (intent.getBooleanExtra("resetFavorites", false)) p.resetFavorites();
        // HomeActivity listens to SharedPreferences and redraws itself.
    }
}
