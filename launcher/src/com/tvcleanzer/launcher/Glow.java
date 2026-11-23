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
        paint.setMaskFilter(new BlurMaskFilter(pad * 0.8f, BlurMaskFilter.Blur.OUTER));
        setColor(0xFFFFFFFF);
        setAlpha(0f);
    }

    void setColor(int c) {
        paint.setColor((c & 0x00FFFFFF) | 0xCC000000);
        invalidate();
    }

    @Override protected void onDraw(Canvas c) {
        float in = pad;
        r.set(in, in, getWidth() - in, getHeight() - in);
        if (oval) c.drawOval(r, paint);
        else c.drawRoundRect(r, radius, radius, paint);
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
            final int N = 12;
            double[] rs = new double[N], gs = new double[N], bs = new double[N], ws = new double[N];
            float[] px = new float[3];
            double colourful = 0, all = 0;
            for (int y = 0; y < 24; y++) {
                for (int x = 0; x < 24; x++) {
                    int p = b.getPixel(x, y);
                    int a = Color.alpha(p);
                    if (a < 40) continue;
                    Color.colorToHSV(p, px);
                    all += a;
                    if (px[1] < 0.25f || px[2] < 0.2f) continue; // white, grey, black: no hue
                    double w = (a / 255.0) * px[1] * px[2];
                    int k = Math.min(N - 1, (int) (px[0] / 360f * N));
                    rs[k] += Color.red(p) * w; gs[k] += Color.green(p) * w; bs[k] += Color.blue(p) * w; ws[k] += w;
                    colourful += a;
                }
            }
            b.recycle();
            int best = 0;
            for (int k = 1; k < N; k++) if (ws[k] > ws[best]) best = k;
            // a mostly white / black icon with a little colour still glows in that colour
            if (ws[best] < 1e-3 || colourful < all * 0.04) return 0xFFFFFFFF;
            float[] hsv = new float[3];
            Color.RGBToHSV((int) (rs[best] / ws[best]), (int) (gs[best] / ws[best]), (int) (bs[best] / ws[best]), hsv);
            if (hsv[1] < 0.18f) return 0xFFFFFFFF; // grey art: a white halo
            hsv[1] = Math.min(1f, hsv[1] * 1.15f);
            hsv[2] = Math.max(hsv[2], 0.9f);
            return Color.HSVToColor(hsv);
        } catch (Throwable t) {
            return 0xFFFFFFFF;
        }
    }
}
