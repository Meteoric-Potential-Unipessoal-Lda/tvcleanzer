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

    AppTile(Context c, AppEntry app, int w, int h, Skin skin, boolean labelsAlways, float textSp) {
        super(c);
        this.app = app;
        this.h = h;
        this.labelsAlways = labelsAlways;
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

        ring = Ui.ring(0xF2FFFFFF, Ui.dp(c, 3), radius);

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
        art.setAlpha(0f);
        art.animate().alpha(1f).setDuration(180).start();
    }

    private void onFocus(boolean has) {
        float s = has ? 1.1f : 1f;
        card.animate().scaleX(s).scaleY(s)
                .translationZ(has ? Ui.dp(getContext(), 20) : 0)
                .setDuration(180).setInterpolator(EASE).start();
        card.setForeground(has ? ring : null);
        if (labelsAlways) {
            label.animate().alpha(has ? 1f : .75f).setDuration(150).start();
        } else {
            label.setTranslationY(has ? -Ui.dp(getContext(), 4) : 0);
            label.animate().alpha(has ? 1f : 0f).translationY(0).setDuration(180).start();
        }
    }
}
