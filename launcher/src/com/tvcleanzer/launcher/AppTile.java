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
    private final FrameLayout holder; // card + ring, scaled together on focus
    private final android.view.View ringView;
    private final ImageView art;
    private final TextView inner;   // name inside the card when there is no banner
    private final TextView label;   // name under the card
    private final GradientDrawable ring;
    private int ringStroke, ringC;
    private final boolean labelsAlways;
    private boolean noLabel;
    private final int w, h;
    /** Soft light across the top of the card while it is selected (a lifted, glossy card). */
    private final android.view.View gloss;
    /** «Свечение» (0.92): the halo behind the card, in the app's colour; null otherwise. */
    private final Glow glow;
    /** «Точка» (1.23, an owner's picture): a small blue dot down and to the right of the selected
     *  app, no frame. Null in the other kinds of highlight. */
    private android.view.View dot;
    /** The ringColor that asks for the dot (0 is «Без рамки», 1 «Свечение», real colours are opaque). */
    static final int RING_DOT = 2;
    private static final int DOT_BLUE = 0xFF0A78FF;
    /** The dot's centre and the notch's radius in the card's own pixels (set by placeDot). */
    private float dotCx, dotCy, notchR;
    private static final android.graphics.Paint CLEAR = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
    static {
        CLEAR.setXfermode(new android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.CLEAR));
    }

    /** Told when a tile gets the focus («Витрина» shows that app above the row). */
    interface Hook { void focused(AppTile t); }
    Hook hook;

    private static final DecelerateInterpolator EASE = new DecelerateInterpolator(1.6f);

    private final float focusScale;
    private final int anim;       // Prefs.ANIM_*
    private final int duration;

    AppTile(Context c, AppEntry app, int w, int h, Skin skin, boolean labelsAlways, float textSp,
            float focusScale, int anim, int ringColor) {
        super(c);
        this.app = app;
        this.labelsAlways = labelsAlways;
        this.anim = anim;
        // no frame (0, «Без рамки») or the halo (1, «Свечение»): a 15 % lift shows the focus
        if (ringColor == 0 || ringColor == 1) focusScale = Math.max(focusScale, 1.15f);
        // soft: half the lift, a bit slower; off: no movement at all (weak TVs)
        this.focusScale = anim == Prefs.ANIM_OFF ? 1f
                : anim == Prefs.ANIM_SOFT ? 1f + (focusScale - 1f) * 0.5f : focusScale;
        this.duration = anim == Prefs.ANIM_OFF ? 0 : anim == Prefs.ANIM_SOFT ? 260 : 180;
        // The zoomed card and its ring stay INSIDE this view: room for them is left around a
        // slightly smaller card, so no parent (shelf, scroll, row) can clip them.
        int room = Math.round(w * (this.focusScale - 1f) / 2f) + Ui.dp(c, 3) + Ui.dp(c, 3);
        int outW = w;
        w = Math.max(1, w - 2 * room);
        h = Math.round(w * (float) h / outW);
        this.w = w;
        this.h = h;
        setPadding(room, room, room, 0);
        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        setClipChildren(false);
        setClipToPadding(false);
        setFocusable(true);
        // Android 8+ paints a grey "default focus highlight" over focusable views without a
        // focused-state background: on tiles it covered the colour ring ("рамка обрезается").
        if (android.os.Build.VERSION.SDK_INT >= 26) setDefaultFocusHighlightEnabled(false);
        setClickable(true);
        setLongClickable(true);

        // square cards (dock, «Витрина», icon grids): rounded like a phone app icon
        float radius = Math.abs(w - h) < w * 0.2f ? Math.max(Ui.dp(c, 14), w * 0.225f) : Ui.dp(c, 14);
        // «Точка» (1.25): the card cuts a round notch round the dot, so the dot sits in the icon
        // with a little air round it (an owner's photo); see cutNotch
        card = new FrameLayout(c) {
            @Override
            protected void dispatchDraw(android.graphics.Canvas cv) {
                super.dispatchDraw(cv);
                cutNotch(cv);
            }
        };
        card.setBackground(Ui.round(skin.tile, radius));
        card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
        card.setClipToOutline(true);
        card.setElevation(Ui.dp(c, 2));
        holder = new FrameLayout(c);
        holder.setClipChildren(false);
        holder.setClipToPadding(false);
        holder.addView(card, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        addView(holder, new LayoutParams(w, h));

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

        GradientDrawable shine = new GradientDrawable();
        shine.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        shine.setGradientCenter(0.25f, 0f);
        shine.setGradientRadius(w * 0.75f);
        shine.setColors(new int[]{0x47FFFFFF, 0x00FFFFFF});
        gloss = new android.view.View(c);
        gloss.setBackground(shine);
        gloss.setAlpha(0f);
        card.addView(gloss, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // The ring is its own view just outside the card, above it: drawn on the card
        // itself it was cut by the card's rounded clip (owners: "выделение отрезано").
        int stroke = Ui.dp(c, 3);
        ringStroke = stroke;
        ringC = ringColor == 1 || ringColor == RING_DOT ? 0 : ringColor;
        ring = Ui.ring(ringC, stroke, radius + stroke);
        if (ringColor == 1) {
            float gp = Math.max(Ui.dp(c, 16), Math.min(w, h) * 0.22f);
            glow = new Glow(c, gp, radius);
            FrameLayout.LayoutParams glp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT);
            int g = Math.round(gp);
            glp.setMargins(-g, -g, -g, -g);
            holder.addView(glow, 0, glp); // behind the card
        } else {
            glow = null;
        }
        int dotSpace = 0; // 0.97: no dot under «Без рамки» any more (the owner: «убираем точку»)
        if (ringColor == RING_DOT) {
            dot = new android.view.View(c);
            dot.setAlpha(0f);
            dot.setScaleX(0.5f);
            dot.setScaleY(0.5f);
            dot.setOutlineProvider(null); // no shadow of its own
            dot.setTranslationZ(Ui.dp(c, 41)); // above the lifted card, like the ring
            holder.addView(dot);
            placeDot(radius, false);
        }
        ringView = new android.view.View(c);
        ringView.setBackground(ring);
        ringView.setOutlineProvider(null); // no shadow of its own
        ringView.setTranslationZ(Ui.dp(c, 40)); // above the lifted card
        ringView.setVisibility(INVISIBLE);
        FrameLayout.LayoutParams rlp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT);
        rlp.setMargins(-stroke, -stroke, -stroke, -stroke);
        holder.addView(ringView, rlp);

        label = Ui.text(c, textSp, 0xFFFFFFFF, "sans-serif-medium");
        label.setGravity(Gravity.CENTER);
        label.setText(app.label);
        label.setAlpha(labelsAlways ? .75f : 0f);
        LayoutParams llp = new LayoutParams(w, LayoutParams.WRAP_CONTENT);
        llp.topMargin = Math.round(h * 0.06f) + Ui.dp(c, 8) + dotSpace;
        addView(label, llp);

        setOnFocusChangeListener((v, has) -> onFocus(has));
    }

    /** Round icons (0.73): the card itself becomes a circle — clear, so no square plate shows
     *  round the round icon (owner's photo: «круглые иконки вписаны в квадратную»), and the
     *  focus ring is a circle too. Square cards only. */
    void setRound(boolean on) {
        if (!on || Math.abs(w - h) > w * 0.2f) return;
        GradientDrawable oval = new GradientDrawable();
        oval.setShape(GradientDrawable.OVAL);
        oval.setColor(0x00000000);
        card.setBackground(oval);
        card.setElevation(0);
        ring.setShape(GradientDrawable.OVAL);
        // 1.16: the ring reaches 2 dp over the round icon's edge: the soft edge of the circle-cut
        // art showed the dark bar through it, a thin black line inside the white ring (UMID, YouTube)
        // 1.17: thinner (UMID: «через чур жирный»): 2 dp outside the icon, 1.5 dp over its edge
        int out = Ui.dp(getContext(), 2), over = Math.round(1.5f * getResources().getDisplayMetrics().density);
        ring.setStroke(out + over, ringC);
        FrameLayout.LayoutParams rl = (FrameLayout.LayoutParams) ringView.getLayoutParams();
        rl.setMargins(-out, -out, -out, -out);
        ringView.setLayoutParams(rl);
        gloss.setVisibility(GONE);
        if (glow != null) { glow.oval = true; glow.invalidate(); }
        placeDot(w / 2f, true);
    }

    /** Where the «Точка» dot sits, inside [holder] so it zooms with the card: on the edge down and
     *  to the right, set into the icon, and the card cuts a notch round it, so a ring of air
     *  shows between the two (1.25, the owner's photo: the dot 22 % of the icon across, its centre
     *  a little outside the edge at 45°, the air 4 %). The same on the rounded corner of a square
     *  card or a banner. [rc] is the corner radius (half the card for a circle). */
    private void placeDot(float rc, boolean round) {
        if (dot == null) return;
        float dp = getResources().getDisplayMetrics().density;
        float m = Math.min(w, h);
        // 1.26 (the owner: «чуть уменьшить и чуть глубже»): 17 % across, its centre inside the edge
        int d = Math.round(Math.max(7 * dp, Math.min(19 * dp, m * 0.17f)));
        float gap = Math.max(2 * dp, Math.min(5 * dp, m * 0.04f));
        double a = Math.toRadians(45);
        float dist = rc * 0.9f;
        float cx = (float) (w - rc + dist * Math.cos(a));
        float cy = (float) (h - rc + dist * Math.sin(a));
        dotCx = cx;
        dotCy = cy;
        notchR = d / 2f + gap;
        card.invalidate();
        GradientDrawable dd = new GradientDrawable();
        dd.setShape(GradientDrawable.OVAL);
        dd.setColor(DOT_BLUE);
        // 1.27: no dark edge (the owner: «чёрную полосу убрать») — the notch already sets it apart
        // the notch needs the card in a layer of its own (a clear circle there, not a hole to the
        // window): only while the dot shows, see onFocus
        dot.setBackground(dd);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(d, d, Gravity.TOP | Gravity.START);
        lp.leftMargin = Math.round(cx - d / 2f);
        lp.topMargin = Math.round(cy - d / 2f);
        dot.setLayoutParams(lp);
    }

    /** «Точка»: the notch round the dot, as wide as the dot is shown (it opens and closes with it). */
    private void cutNotch(android.graphics.Canvas cv) {
        if (dot == null || notchR <= 0) return;
        float a = dot.getAlpha();
        if (a < 0.02f || card.getLayerType() == LAYER_TYPE_NONE) return;
        cv.drawCircle(dotCx, dotCy, notchR * a * dot.getScaleX(), CLEAR);
    }

    /** Size of the card itself (what the art is drawn for). */
    int cardW() { return w; }
    int cardH() { return h; }

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
        if (glow != null) glow.setColor(Glow.colourOf(d));
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
        if (has && hook != null) hook.focused(this);
        if (anim == Prefs.ANIM_OFF) gloss.setAlpha(has ? 1f : 0f);
        else gloss.animate().alpha(has ? 1f : 0f).setDuration(duration).start();
        float s = has ? focusScale : 1f;
        float z = anim == Prefs.ANIM_OFF ? 0 : Ui.dp(getContext(), anim == Prefs.ANIM_SOFT ? 10 : 20);
        holder.animate().scaleX(s).scaleY(s).setDuration(duration).setInterpolator(EASE).start();
        card.animate().translationZ(has ? z : 0).setDuration(duration).setInterpolator(EASE).start();
        ringView.setVisibility(has && glow == null ? VISIBLE : INVISIBLE);
        if (dot != null) {
            if (has) card.setLayerType(LAYER_TYPE_HARDWARE, null);
            if (anim == Prefs.ANIM_OFF) {
                dot.setAlpha(has ? 1f : 0f);
                dot.setScaleX(1f);
                dot.setScaleY(1f);
                card.invalidate();
                if (!has) card.setLayerType(LAYER_TYPE_NONE, null);
            } else {
                float ds = has ? 1f : 0.5f;
                dot.animate().alpha(has ? 1f : 0f).scaleX(ds).scaleY(ds).setDuration(duration)
                        .setInterpolator(EASE)
                        .setUpdateListener(va -> card.invalidate()) // the notch opens with the dot
                        .withEndAction(() -> {
                            if (!isFocused()) card.setLayerType(LAYER_TYPE_NONE, null);
                            card.invalidate();
                        })
                        .start();
            }
        }
        if (glow != null) {
            if (anim == Prefs.ANIM_OFF) glow.setAlpha(has ? 1f : 0f);
            else glow.animate().alpha(has ? 1f : 0f).setDuration(duration).start();
        }
        if (labelsAlways) {
            label.animate().alpha(has ? 1f : .75f).setDuration(Math.min(duration, 150)).start();
        } else {
            label.setTranslationY(has && duration > 0 ? -Ui.dp(getContext(), 4) : 0);
            label.animate().alpha(has ? 1f : 0f).translationY(0).setDuration(duration).start();
        }
    }

    /** No name under the card at all (0.83 «Названия приложений: Скрыто»): the row gets lower. */
    /** Room under the card inside this tile: its name (shown or waiting for the focus), or the
     *  zoom room when the names are off. */
    int roomBelow() {
        if (noLabel || label.getVisibility() == GONE) return getPaddingBottom();
        LayoutParams lp = (LayoutParams) label.getLayoutParams();
        label.measure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
        return lp.topMargin + label.getMeasuredHeight();
    }

    void hideLabel() {
        noLabel = true;
        label.setVisibility(GONE);
        // the room for the zoomed card below too, as above: the icon in the middle of the dock
        // (0.85, an owner's photo: it sat low with the names gone)
        setPadding(getPaddingLeft(), getPaddingTop(), getPaddingRight(), getPaddingTop());
    }

    /** Move mode: arrows around the name, name always visible. */
    void setMoving(boolean on) {
        if (noLabel) label.setVisibility(on ? VISIBLE : GONE);
        label.setText(on ? "◀  " + app.label + "  ▶" : app.label);
        label.animate().cancel();
        label.setAlpha(on ? 1f : (labelsAlways ? .75f : (isFocused() ? 1f : 0f)));
        ringView.setAlpha(on ? 0.6f : 1f);
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
