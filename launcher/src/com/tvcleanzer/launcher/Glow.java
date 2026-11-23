package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BlurMaskFilter;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.view.View;

/**
 * «Свечение» (0.92, an idea from the chat): a soft blurred halo round the selected app in the
 * app's own colour, instead of a frame. Drawn behind the card, the card's shape (rounded or
 * round), blur by the software layer (BlurMaskFilter works there on every Android).
 */
final class Glow extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final float pad, radius;
    boolean oval;

    Glow(Context c, float pad, float radius) {
        super(c);
        this.pad = pad;
        this.radius = radius;
        setLayerType(LAYER_TYPE_SOFTWARE, null);
        paint.setMaskFilter(new BlurMaskFilter(pad * 0.75f, BlurMaskFilter.Blur.NORMAL));
        setColor(0xFFFFFFFF);
        setAlpha(0f);
    }

    void setColor(int c) {
        paint.setColor((c & 0x00FFFFFF) | 0xD9000000);
        invalidate();
    }

    @Override protected void onDraw(Canvas c) {
        float in = pad * 0.85f;
        r.set(in, in, getWidth() - in, getHeight() - in);
        if (oval) c.drawOval(r, paint);
        else c.drawRoundRect(r, radius + pad * 0.15f, radius + pad * 0.15f, paint);
    }

    /** The colour an icon «is»: saturated pixels count most; grey / white art gives white. */
    static int colourOf(Drawable d) {
        try {
            Bitmap b = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(b);
            android.graphics.Rect old = new android.graphics.Rect(d.getBounds());
            d.setBounds(0, 0, 24, 24);
            d.draw(c);
            d.setBounds(old);
            double rs = 0, gs = 0, bs = 0, ws = 0;
            for (int y = 0; y < 24; y++) {
                for (int x = 0; x < 24; x++) {
                    int p = b.getPixel(x, y);
                    int a = Color.alpha(p), rr = Color.red(p), gg = Color.green(p), bb = Color.blue(p);
                    if (a < 40) continue;
                    int mx = Math.max(rr, Math.max(gg, bb)), mn = Math.min(rr, Math.min(gg, bb));
                    double w = (a / 255.0) * (0.05 + (mx - mn) / 255.0) * (0.3 + mx / 255.0);
                    rs += rr * w; gs += gg * w; bs += bb * w; ws += w;
                }
            }
            b.recycle();
            if (ws < 1e-3) return 0xFFFFFFFF;
            float[] hsv = new float[3];
            Color.RGBToHSV((int) (rs / ws), (int) (gs / ws), (int) (bs / ws), hsv);
            if (hsv[1] < 0.18f) return 0xFFFFFFFF; // grey art: a white halo
            hsv[1] = Math.min(1f, hsv[1] * 1.15f);
            hsv[2] = Math.max(hsv[2], 0.9f);
            return Color.HSVToColor(hsv);
        } catch (Throwable t) {
            return 0xFFFFFFFF;
        }
    }
}
