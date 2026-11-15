package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.ViewOutlineProvider;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Focusable app card. On focus it lifts (scale + shadow) and gets a light
 * ring, like tvOS. Name below appears on focus, or always (setting).
 */
final class AppTile extends LinearLayout {
    final AppEntry app;
    private final FrameLayout card;
    private final ImageView art;
    private final TextView inner;   // name inside the card when there is no banner
    private final TextView label;   // name under the card
    private final GradientDrawable ring;
    private final boolean labelsAlways;
    private final int h;

    private static final DecelerateInterpolator EASE = new DecelerateInterpolator(1.6f);

    private final float focusScale;
    private final int anim;       // Prefs.ANIM_*
    private final int duration;

    AppTile(Context c, AppEntry app, int w, int h, Skin skin, boolean labelsAlways, float textSp,
            float focusScale, int anim, int ringColor) {
        super(c);
        this.app = app;
        this.h = h;
        this.labelsAlways = labelsAlways;
        this.anim = anim;
        // soft: half the lift, a bit slower; off: no movement at all (weak TVs)
        this.focusScale = anim == Prefs.ANIM_OFF ? 1f
                : anim == Prefs.ANIM_SOFT ? 1f + (focusScale - 1f) * 0.5f : focusScale;
        this.duration = anim == Prefs.ANIM_OFF ? 0 : anim == Prefs.ANIM_SOFT ? 260 : 180;
        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        setClipChildren(false);
        setClipToPadding(false);
        setFocusable(true);
        setClickable(true);
        setLongClickable(true);

        float radius = Ui.dp(c, 14);
        card = new FrameLayout(c);
        card.setBackground(Ui.round(skin.tile, radius));
        card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
        card.setClipToOutline(true);
        card.setElevation(Ui.dp(c, 2));
        addView(card, new LayoutParams(w, h));

        art = new ImageView(c);
        card.addView(art, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        inner = Ui.text(c, textSp, 0xE6FFFFFF, "sans-serif-medium");
        inner.setGravity(Gravity.CENTER);
        inner.setText(app.label);
        FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM);
        int pad = Ui.dp(c, 8);
        inner.setPadding(pad, 0, pad, Math.round(h * 0.1f));
        card.addView(inner, ilp);

        ring = Ui.ring(ringColor, Ui.dp(c, 3), radius);

        label = Ui.text(c, textSp, 0xFFFFFFFF, "sans-serif-medium");
        label.setGravity(Gravity.CENTER);
        label.setText(app.label);
        label.setAlpha(labelsAlways ? .75f : 0f);
        LayoutParams llp = new LayoutParams(w, LayoutParams.WRAP_CONTENT);
        llp.topMargin = Math.round(h * 0.06f) + Ui.dp(c, 8);
        addView(label, llp);

        setOnFocusChangeListener((v, has) -> onFocus(has));
    }

    /** Called from the art loader on the main thread. */
    void setArt(Drawable d, boolean isBanner) {
        if (d == null) return;
        FrameLayout.LayoutParams lp;
        if (isBanner) {
            art.setScaleType(ImageView.ScaleType.CENTER_CROP);
            lp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT);
            inner.setVisibility(GONE);
        } else {
            art.setScaleType(ImageView.ScaleType.FIT_CENTER);
            int s = Math.round(h * 0.44f);
            lp = new FrameLayout.LayoutParams(s, s, Gravity.CENTER_HORIZONTAL | Gravity.TOP);
            lp.topMargin = Math.round(h * 0.14f);
            inner.setVisibility(VISIBLE);
        }
        art.setLayoutParams(lp);
        art.setImageDrawable(d);
        if (anim == Prefs.ANIM_OFF) {
            art.setAlpha(1f);
        } else {
            art.setAlpha(0f);
            art.animate().alpha(1f).setDuration(180).start();
        }
    }

    private void onFocus(boolean has) {
        // a zoomed tile must be drawn over the next row / the shelf edge
        android.view.ViewParent parent = getParent();
        if (parent instanceof android.view.View) ((android.view.View) parent).setTranslationZ(has ? 2f : 0f);
        setTranslationZ(has ? 1f : 0f);
        float s = has ? focusScale : 1f;
        float z = anim == Prefs.ANIM_OFF ? 0 : Ui.dp(getContext(), anim == Prefs.ANIM_SOFT ? 10 : 20);
        card.animate().scaleX(s).scaleY(s)
                .translationZ(has ? z : 0)
                .setDuration(duration).setInterpolator(EASE).start();
        card.setForeground(has ? ring : null);
        if (labelsAlways) {
            label.animate().alpha(has ? 1f : .75f).setDuration(Math.min(duration, 150)).start();
        } else {
            label.setTranslationY(has && duration > 0 ? -Ui.dp(getContext(), 4) : 0);
            label.animate().alpha(has ? 1f : 0f).translationY(0).setDuration(duration).start();
        }
    }

    /** First appearance of the home screen: tiles rise in one after another. */
    void enter(int index) {
        if (anim != Prefs.ANIM_FULL) return;
        setAlpha(0f);
        setTranslationY(Ui.dp(getContext(), 18));
        animate().alpha(1f).translationY(0).setStartDelay(60L + Math.min(index, 14) * 35L)
                .setDuration(320).setInterpolator(EASE).start();
    }
}
