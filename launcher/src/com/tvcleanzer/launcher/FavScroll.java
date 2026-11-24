package com.tvcleanzer.launcher;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.widget.HorizontalScrollView;

/**
 * The one-row favourites (1.15, UMID's photos): a selected app keeps [margin] from the bar's ends
 * (the plain scroll view put the first one right on the edge), and an app cut off at an end is cut
 * [clip] inside the glass instead of sticking to its edge. 1.14 did it with a fading edge: that
 * drew a dark band over the last app, the lifted card and its ring not faded with it.
 */
final class FavScroll extends HorizontalScrollView {
    private final int margin, clip;

    FavScroll(Context c, int margin, int clip) {
        super(c);
        this.margin = margin;
        this.clip = clip;
    }

    @Override
    protected int computeScrollDeltaToGetChildRectOnScreen(Rect rect) {
        Rect r = new Rect(rect);
        r.left -= margin;
        r.right += margin;
        return super.computeScrollDeltaToGetChildRectOnScreen(r);
    }

    @Override
    protected void dispatchDraw(Canvas c) {
        int x = getScrollX();
        c.save();
        c.clipRect(x + clip, 0, x + getWidth() - clip, getHeight());
        super.dispatchDraw(c);
        c.restore();
    }
}
