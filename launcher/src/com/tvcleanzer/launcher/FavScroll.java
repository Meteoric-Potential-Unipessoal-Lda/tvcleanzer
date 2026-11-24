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
        // 1.17: cut only where more apps go on: at an end the selected app and its ring stay whole
        // (the last one was cut at the right end)
        // 1.18: by where the apps really end, not by the scroll position — at the last app the
        // view can stop a little short of its end, and the last one was still cut (UMID)
        int x = getScrollX();
        android.view.View row = getChildCount() == 0 ? null : getChildAt(0);
        boolean moreLeft = row != null && row.getLeft() < x - 1;
        boolean moreRight = row != null && row.getRight() > x + getWidth() + 1;
        c.save();
        c.clipRect(x + (moreLeft ? clip : -getWidth()), 0, x + getWidth() - (moreRight ? clip : -getWidth()), getHeight());
        super.dispatchDraw(c);
        c.restore();
    }
}
