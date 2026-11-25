package com.tvcleanzer.launcher;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.List;

/**
 * 1.46 «Сейчас играет» (an idea from couch-tv): a small card on the home screen with what plays
 * (music in the background, a podcast, a paused video), its cover from the session, and
 * ⏮ ⏯ ⏭; OK on the words opens the app. Shown only while something plays or is paused.
 * Off by default; needs the notification listener the phone allows (NowPlayingListener).
 */
final class NowPlaying extends LinearLayout {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ImageView art;
    private final TextView title, sub;
    private final TextView playBtn;
    private MediaSessionManager msm;
    private MediaController ctl;
    private MediaSessionManager.OnActiveSessionsChangedListener sessions;
    private final MediaController.Callback cb = new MediaController.Callback() {
        @Override public void onPlaybackStateChanged(PlaybackState s) { show(); }
        @Override public void onMetadataChanged(MediaMetadata m) { show(); }
        @Override public void onSessionDestroyed() { pick(null); }
    };

    /** Has the phone allowed the listener (so the TV's sessions can be seen)? */
    static boolean allowed(Context c) {
        try {
            String s = Settings.Secure.getString(c.getContentResolver(), "enabled_notification_listeners");
            return s != null && s.contains(c.getPackageName() + "/");
        } catch (Throwable t) {
            return false;
        }
    }

    NowPlaying(Context c) {
        super(c);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        int p = Ui.dp(c, 10);
        setPadding(p, p, p, p);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xD9141A24);
        bg.setCornerRadius(Ui.dp(c, 18));
        bg.setStroke(Math.max(1, Ui.dp(c, 1)), 0x26FFFFFF);
        setBackground(bg);
        setVisibility(GONE);

        art = new ImageView(c);
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setClipToOutline(true);
        GradientDrawable ab = new GradientDrawable();
        ab.setColor(0x33FFFFFF);
        ab.setCornerRadius(Ui.dp(c, 10));
        art.setBackground(ab);
        int as = Ui.dp(c, 52);
        addView(art, new LayoutParams(as, as));

        LinearLayout words = new LinearLayout(c);
        words.setOrientation(VERTICAL);
        words.setPadding(Ui.dp(c, 12), 0, Ui.dp(c, 8), 0);
        title = Ui.text(c, 15, 0xFFFFFFFF, "sans-serif-medium");
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        sub = Ui.text(c, 13, 0xB3FFFFFF, "sans-serif");
        sub.setSingleLine(true);
        sub.setEllipsize(TextUtils.TruncateAt.END);
        words.addView(title);
        words.addView(sub);
        words.setFocusable(true);
        words.setClickable(true);
        plate(words);
        words.setOnClickListener(v -> openApp());
        addView(words, new LayoutParams(Ui.dp(c, 220), LayoutParams.WRAP_CONTENT));

        addView(button("⏮", KeyEvent.KEYCODE_MEDIA_PREVIOUS));
        playBtn = button("⏯", KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE);
        addView(playBtn);
        addView(button("⏭", KeyEvent.KEYCODE_MEDIA_NEXT));
    }

    private TextView button(String glyph, final int key) {
        TextView b = Ui.text(getContext(), 20, 0xFFFFFFFF, "sans-serif");
        b.setText(glyph);
        b.setGravity(Gravity.CENTER);
        int s = Ui.dp(getContext(), 44);
        b.setLayoutParams(new LayoutParams(s, s));
        b.setFocusable(true);
        b.setClickable(true);
        plate(b);
        b.setOnClickListener(v -> press(key));
        return b;
    }

    private void plate(final View v) {
        final float r = Ui.dp(getContext(), 12);
        v.setOnFocusChangeListener((x, has) -> x.setBackground(has ? Ui.round(0x40FFFFFF, r) : null));
    }

    private void press(int key) {
        MediaController c = ctl;
        if (c == null) return;
        try {
            MediaController.TransportControls t = c.getTransportControls();
            if (key == KeyEvent.KEYCODE_MEDIA_NEXT) t.skipToNext();
            else if (key == KeyEvent.KEYCODE_MEDIA_PREVIOUS) t.skipToPrevious();
            else {
                PlaybackState s = c.getPlaybackState();
                if (s != null && s.getState() == PlaybackState.STATE_PLAYING) t.pause(); else t.play();
            }
        } catch (Throwable t) {
            HomeKeyService.log("now playing: " + t);
        }
    }

    private void openApp() {
        MediaController c = ctl;
        if (c == null) return;
        try {
            if (c.getSessionActivity() != null) {
                c.getSessionActivity().send();
                return;
            }
            android.content.pm.PackageManager pm = getContext().getPackageManager();
            Intent i = pm.getLeanbackLaunchIntentForPackage(c.getPackageName());
            if (i == null) i = pm.getLaunchIntentForPackage(c.getPackageName());
            if (i != null) getContext().startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Throwable t) {
            HomeKeyService.log("now playing: " + t);
        }
    }

    /** The home came to the front: follow the TV's sessions. */
    void resume() {
        if (!allowed(getContext())) {
            setVisibility(GONE);
            return;
        }
        try {
            msm = (MediaSessionManager) getContext().getSystemService(Context.MEDIA_SESSION_SERVICE);
            ComponentName me = new ComponentName(getContext(), NowPlayingListener.class);
            sessions = list -> main.post(() -> pick(list));
            msm.addOnActiveSessionsChangedListener(sessions, me, main);
            pick(msm.getActiveSessions(me));
        } catch (Throwable t) {
            HomeKeyService.log("now playing: " + t);
            setVisibility(GONE);
        }
    }

    void pause() {
        try { if (msm != null && sessions != null) msm.removeOnActiveSessionsChangedListener(sessions); } catch (Throwable ignored) {}
        sessions = null;
        if (ctl != null) try { ctl.unregisterCallback(cb); } catch (Throwable ignored) {}
        ctl = null;
    }

    /** The session to show: one that plays, else the first paused one with a title. */
    private void pick(List<MediaController> list) {
        MediaController best = null;
        if (list != null) {
            for (MediaController c : list) {
                if (c.getPackageName().equals(getContext().getPackageName())) continue;
                PlaybackState s = c.getPlaybackState();
                int st = s == null ? 0 : s.getState();
                if (st == PlaybackState.STATE_PLAYING) { best = c; break; }
                if (best == null && st == PlaybackState.STATE_PAUSED && c.getMetadata() != null) best = c;
            }
        }
        if (ctl != null && (best == null || !best.getSessionToken().equals(ctl.getSessionToken()))) {
            try { ctl.unregisterCallback(cb); } catch (Throwable ignored) {}
            ctl = null;
        }
        if (best != null && ctl == null) {
            ctl = best;
            try { ctl.registerCallback(cb, main); } catch (Throwable ignored) {}
        }
        show();
    }

    private void show() {
        MediaController c = ctl;
        MediaMetadata m = c == null ? null : c.getMetadata();
        PlaybackState s = c == null ? null : c.getPlaybackState();
        int st = s == null ? 0 : s.getState();
        CharSequence t = m == null ? null : m.getText(MediaMetadata.METADATA_KEY_TITLE);
        if (c == null || TextUtils.isEmpty(t) || (st != PlaybackState.STATE_PLAYING && st != PlaybackState.STATE_PAUSED
                && st != PlaybackState.STATE_BUFFERING)) {
            if (getVisibility() != GONE) setVisibility(GONE);
            return;
        }
        title.setText(t);
        CharSequence a = m.getText(MediaMetadata.METADATA_KEY_ARTIST);
        if (TextUtils.isEmpty(a)) a = m.getText(MediaMetadata.METADATA_KEY_ALBUM);
        if (TextUtils.isEmpty(a)) a = label(c.getPackageName());
        sub.setText(a);
        Bitmap b = m.getBitmap(MediaMetadata.METADATA_KEY_ART);
        if (b == null) b = m.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART);
        if (b == null) b = m.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON);
        art.setImageBitmap(b);
        art.setVisibility(b == null ? GONE : VISIBLE);
        playBtn.setText(st == PlaybackState.STATE_PLAYING ? "⏸" : "▶");
        setVisibility(VISIBLE);
    }

    private String label(String pkg) {
        try {
            android.content.pm.PackageManager pm = getContext().getPackageManager();
            return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString();
        } catch (Throwable t) {
            return pkg;
        }
    }
}
