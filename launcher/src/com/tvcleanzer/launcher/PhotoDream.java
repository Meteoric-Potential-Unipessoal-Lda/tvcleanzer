package com.tvcleanzer.launcher;

import android.service.dreams.DreamService;

/**
 * Photo frame screensaver (PhotoFrame draws it). The TV starts it after the idle time the phone
 * sets; FrameActivity shows the same frame on request where the TV will not start it at once.
 */
public class PhotoDream extends DreamService {
    private PhotoFrame frame;

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false);
        setFullscreen(true);
        frame = new PhotoFrame(this);
        android.view.View root = frame.build();
        setScreenBright(!frame.clockOnly());
        setContentView(root);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        if (frame != null) frame.start();
    }

    @Override
    public void onDreamingStopped() {
        if (frame != null) frame.stop();
        super.onDreamingStopped();
    }

    @Override
    public void onDetachedFromWindow() {
        if (frame != null) frame.destroy();
        frame = null;
        super.onDetachedFromWindow();
    }
}
