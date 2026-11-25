package com.tvcleanzer.launcher;

import android.service.notification.NotificationListenerService;

/**
 * 1.46: only the key to the TV's media sessions for «Сейчас играет» (NowPlaying). Android lets an
 * app see what plays only through an allowed notification listener; the phone allows it over ADB
 * when the owner switches the card on (cmd notification allow_listener) and takes it back when
 * it is switched off. Notifications themselves are never read.
 */
public class NowPlayingListener extends NotificationListenerService {
}
