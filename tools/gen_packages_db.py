#!/usr/bin/env python3
"""Builds TVCleanzer assets/packages.json from CleanYourTV per-model lists.

Usage (needs the old packages.json for curated labels):
  mkdir ex && <download https://raw.githubusercontent.com/Gathin23/cleanyourtv/main/examples/<folder>/debloat.txt
               for every folder listed in examples/README.md into ex/<folder>.txt>
  DB_VERSION=2026111001 python3 -I gen_packages_db.py path/to/old/packages.json
Then copy packages.json to assets/ and commit: phones pick it up from GitHub.
"""
import re, json, os, collections, sys
PKG = r'[a-zA-Z][\w]*(?:\.[\w]+)+'
act_re = re.compile(r'^(' + PKG + r')\s*(?:#\s*(.*))?$')
com_re = re.compile(r'^#\s*(' + PKG + r')\s*(?:#\s*(.*))?$')

# Never touch (ported from tv-kit Test-Protected + launcher/setup lessons)
PROTECTED = [r'^android$',
 r'^com\.android\.(systemui|settings|providers\..*|shell|phone|bluetooth|packageinstaller|permissioncontroller|inputdevices|externalstorage|webview|networkstack.*|tv\.settings|tv\.remote.*|keychain|location\.fused|se|nfc|server\..*|captiveportallogin|certinstaller|documentsui|vpndialogs|wallpaperbackup|backupconfirm|proxyhandler|sharedstoragebackup|dynsystem|localtransport|statementservice|tv)$',
 r'^com\.google\.android\.(gms|gsf|gsf\.login|ext\..*|webview|packageinstaller|permissioncontroller|tv\.remote\.service|tvlauncher|apps\.tv\.launcherx|leanbacklauncher|inputmethod\..*|tts|configupdater|networkstack.*|modulemetadata|overlay\..*)$',
 r'^com\.android\.vending$',
 # Live Channels: the tuner player behind «Live TV» on many Android TVs (MiTV L55M5-5ARU report)
 r'^com\.google\.android\.tv$',
 r'inputmethod|keyboard|sogou|latinime|leanbackime|(^|[._])ime([._]|$)',
 r'bluetooth|(^|[._])\w*remote\w*([._]|$)|(^|[._])(rcu\w*|autopair|btmanager)([._]|$)',
 r'(^|[._])(mediatek|realtek|amlogic|rtk|mstar|hisilicon|novatek)([._]|$)',
 r'(^|[._])(tvcenter|tvplayer|livetv|playtv|tvservice|tvmanager|tvinput\w*|tis|hdmi\w*|cec|dtv\w*|tuner\w*|atv\.service)([._]|$)',
 r'^org\.droidtv\.(settings|tvsettings|tvsystemui|systemui|channels|epg|euinstallersat|euinstallertc|tvplayer|playtv)$',
 r'(^|[._])\w*(update|upgrade)\w*([._]|$)|(^|[._])f?ota([._]|$)',
 r'setupwraith|setupwizard|partnercustomizer',
 r'^mitv\.service$', r'^com\.mitv\.overseaservice$',
 r'vpn|proxy', r'^flar2\.homebutton$',
 # home screens of any brand: our app never removes the TV's own launcher
 r'^com\.mitv\.tvhome(\.atv)?$', r'^com\.amazon\.tv\.launcher$', r'^com\.tcl\.waterfall\.overseas$',
 r'launcher$', r'(^|[._])home$', r'^com\.tvcleanzer\.',
]
PROTECTED.append(r'webview'); PROTECTED.append(r'tclhome|smarttvhome|litehome|tvhome_master')
# Projectors: optics, keystone/focus, sensors and the vendor services behind the remote and the
# projection settings (CleanYourTV projector lists, "DO NOT DISABLE" / "Kept on purpose" sections).
PROTECTED += [
 r'keystone|autokst|focus|(^|[._])tof([._]|$)|dewarp|(^|[._])ptz([._]|$)|imaging|projector|projection|screenfit|obstacle|optical|lightengine',
 r'^com\.xgimi\.(xrmservice|xgimiservice|misckey|windowsystem|uiconfiguration|tvinput|simpservice|soundermodeservice|bluetoothservice|starmirror|autoinstall|overseas\..*)$',
 r'^com\.sdmc\.(kt|service|btservice|globalkey|remotecontrolservice|keyburn|standbyserver|sdmcplatform|sdmcservicehelper|bluetoothconnect)$',
 r'^com\.zhixin\.(nebulasmart|apphelper|remoteautopair|nebulasetupwizard)$',
 r'^com\.oceanwing\.(nebulalinker|receiver)$',
 r'^com\.hysd\.', r'^com\.htc\.magcubicos$',
 r'^com\.softwinner\.(awsource|vis|awlivetv|tv\..*)$', r'^com\.android\.(ytb|nfx)$',
 r'^com\.epson\.(droidsettings|flexiblepicture|installation|warningui|bizmodeui)$',
 r'^com\.benq\.(benqnewrc|appsmanager)$', r'^com\.inspur\.benq\.remoterc$',
 r'^com\.droidlogic\.(tv\..*|tvinput|android\.tv)$',
 r'^com\.fengmi\.(platform|fmsettings)$',
 r'^com\.jmgo\.(hippo|autobrightness|android\.tv\..*)$',
 # Yandex TV (YaOS): home, account/system glue, settings, inputs, keyboard, remote, store/payment/player.
 # Efir (com.yandex.tv.input.efir) stays optional: HDMI and the tuner live in the vendor TV input.
 r'^com\.yandex\.tv\.(home|services.*|settings.*|setupwizard|input\.(?!efir).*|live|keyboard|vendor\.config)$',
 r'^com\.yandex\.(io\.sdk|webview|server\..*|devices\.(appstore|payment|player)|launcher\.updaterapp)$',
 r'^com\.yandex_uni\.rro\.',
 r'^ru\.yandex\.(bleremotecontrol|androidkeyboard\.tv)$',
 # Sber (Salute TV / StarOS): platform service + assistant, HDMI inputs, keyboard, WebView, settings, the
 # app catalogue (the only way apps get updated), overlays (CleanYourTV sber-salute-tv-at30a6, pb766).
 r'^ru\.sberdevices\.(services(\..*)?|assistant|tvinputs|app\..*|webview|systemui|sberdevicesservicesystem|location\..*|settings|starlauncher|starmarket|updater|tvfactoryhelper)$',
 r'^ru\.sberdevices\..*(overlay|\.rro|resources?)',
 r'^com\.sberbank\.settings$',
 # CVTE/MStar boards (Yandex, Sber, Haier, Hi, Leff…): factory menu and test tools, firmware updates, TV API.
 r'factory|(^|[._])fac([._]|$)|hisensefac|hkcfac|(^|[._])aging([._]|$)|autotest|(^|[._])burn([._]|$)|license\.at$',
 r'^com\.cvte\.tv\.(setting|api.*|tools)$',
 r'^com\.cultraview\.osupdate$',
 r'^com\.example\.upgrad$',
 # TCL Google TV: Quick Panel (remote ⚙ / Source), shortcut menu, TCL TV player
 r'^com\.tcl\.(suspension|common\.shortcutmenu|tv|sourcemenu)$',
]
PROT = [re.compile(p, re.I) for p in PROTECTED]
# tvmanager is protected by the TV-service rule, but Xiaomi's "TV Manager" cleaner is safe; keep it protected anyway (safe side).
ASK = re.compile(r'media|player|usb|talkback|marvin|accessib|katniss|assistant|voice|speech|pumpkin|hotword|dream|backdrop|screensaver|mediashell|cast|miplay|smartshare|mi_connect|airplay|wfd|miracast|dlna|music|video|youtube|netflix|amazon|prime|disney|spotify|kodi|gallery|photo|browser|livingroom|alarm|clock|alexa|fitness|kinopoisk|ivi|okko|wink|premier|start|more\.tv|hbo|max|plex|vlc|iptv|tv\.player|sber|yandex|vk')

CATS = [
 (r'\bacr\b|automatic content|alphonso|samba|anoki|viewing data|content recognition', 'Следит, что вы смотрите (ACR)'),
 (r'telemetr|analytic|statistic|tracking|tracker|logger|usage ?log|metric|crash ?report|diagnos|stats|data collect|consent', 'Телеметрия: отправляет данные производителю'),
 (r'\bads?\b|advert|promo|recommend|sponsor|featured|content rows?|discover|shopping|deals', 'Реклама и навязанные рекомендации'),
 (r'demo|retail|store mode|shop mode|showroom', 'Демо-режим для витрины магазина'),
 (r'feedback|bug ?report', 'Отчёты об ошибках разработчику'),
 (r'auto-?install|partner ?(app|install|setup)|attribution', 'Ставит партнёрские приложения без спроса'),
 (r'cleaner|booster|speed ?test|optimi[sz]', '«Ускоритель»-пустышка, сам ест память'),
 (r'game|gaming', 'Игровой сервис, на ТВ обычно не нужен'),
 (r'manual|tutorial|help|tips|guide', 'Справка и обучалки производителя'),
 (r'stub|placeholder|link', 'Пустая заглушка производителя'),
]
CATS = [(re.compile(a, re.I), b) for a, b in CATS]
DEFAULT_REASON = 'Предустановлено производителем, на ТВ обычно не нужно'

BRANDS = [('xiaomi','Xiaomi'),('miui','Xiaomi'),('mitv','Xiaomi'),('google','Google'),('amazon','Amazon'),
 ('tcl','TCL'),('sony','Sony'),('droidtv','Philips'),('philips','Philips'),('haier','Haier'),('cvte','CVTE'),
 ('hisense','Hisense'),('skyworth','Skyworth'),('sharp','Sharp'),('samsung','Samsung'),('lg','LG'),('netflix','Netflix'),
 ('anoki','Anoki'),('zeasn','Zeasn'),('toshiba','Toshiba'),('panasonic','Panasonic'),('nvidia','NVIDIA'),('sber','Sber'),('yandex','Yandex')]
SKIPSEG = {'com','android','google','tv','apps','app','xiaomi','miui','mitv','amazon','org','net','cn','ru','atv','service','services','sdk','client','tvos','smart'}

def pretty(pkg):
    segs = pkg.split('.')
    brand = next((b for k, b in BRANDS if any(k == s.lower() or s.lower().startswith(k) for s in segs[:3])), None)
    meaningful = [s for s in segs if s.lower() not in SKIPSEG] or [segs[-1]]
    name = meaningful[-1]
    if len(meaningful) >= 2 and len(name) <= 3: name = meaningful[-2] + ' ' + name
    name = re.sub(r'([a-z])([A-Z])', r'\1 \2', name).replace('_', ' ').strip()
    name = name[:1].upper() + name[1:]
    return f'{brand} · {name}' if brand and brand.lower() not in name.lower() else name

def label_from_comment(c):
    if not c: return None
    m = re.search(r'"([^"]{2,30})"', c)
    if m: return m.group(1)
    c = c.strip().rstrip('.')
    if len(c) <= 26 and re.match(r'^[A-Z0-9]', c) and len(c.split()) <= 4 and not re.search(r'\b(off|keep|re-?enable|disabled?|needed|used|if|only|see|by|not|stays?)\b', c, re.I):
        return c
    return None


T='Телеметрия: отправляет данные производителю'; A='Реклама и навязанные рекомендации'; R='Следит, что вы смотрите (ACR)'
P='Ставит партнёрские приложения без спроса'; D='Демо-режим для витрины магазина'; F='Обычное приложение: уберите, если не пользуетесь'
OVERRIDES = {
 'com.google.android.feedback': ('Отзывы Google', 'Отправляет отчёты об ошибках в Google'),
 'com.google.android.play.games': ('Play Игры', 'Игровой сервис Google, на ТВ почти не используется'),
 'com.google.android.videos': ('Google Play Фильмы', F),
 'com.google.android.tvrecommendations': ('Рекомендации Google', A),
 'com.google.android.partnersetup': ('Настройка партнёров Google', P),
 'com.google.android.youtube.tvmusic': ('YouTube Music', F),
 'com.google.android.syncadapters.calendar': ('Синхронизация календаря', 'Фоновая синхронизация, на ТВ бесполезна'),
 'com.google.android.katniss': ('Голосовой поиск Google', 'Уберите, только если не ищете голосом с пульта'),
 'com.android.printspooler': ('Печать', 'Служба печати, на ТВ не нужна'),
 'com.google.android.backdrop': ('Заставка Google (Ambient)', F),
 'com.android.tv.feedbackconsent': ('Согласие на отзывы', T),
 'com.google.android.marvin.talkback': ('TalkBack', 'Озвучка экрана для незрячих: уберите, если не пользуетесь'),
 'com.android.adservices.api': ('Рекламные сервисы Android', A),
 'fusion.android.tv.demo': ('Демо-режим', D),
 'com.google.android.onetimeinitializer': ('Первичная настройка Google', 'Нужна один раз при первом включении'),
 'com.tcl.esticker': ('Наклейки-реклама TCL', D),
 'com.android.ondevicepersonalization.services': ('Персонализация рекламы', A),
 'com.android.federatedcompute.services': ('Обучение рекламы на устройстве', A),
 'com.google.android.apps.tv.dreamx': ('Заставка Google TV', F),
 'com.amazon.amazonvideo.livingroom': ('Prime Video', F),
 'com.google.android.tv.bugreportsender': ('Отчёты об ошибках', T),
 'com.tcl.messagebox': ('Сообщения TCL', A),
 'android.autoinstalls.config.google.gtvpai': ('Автоустановка Google TV', P),
 'com.tcl.usercenter': ('Аккаунт TCL', 'Навязчиво просит войти в аккаунт TCL'),
 'com.google.android.apps.mediashell': ('Chromecast', 'Трансляция с телефона на ТВ: уберите, только если не транслируете'),
 'com.tcl.guard': ('Очистка TCL', '«Ускоритель»-пустышка, сам ест память'),
 'com.miui.tv.analytics': ('Аналитика Xiaomi', T),
 'com.qterics.da.product': ('Агент Qterics', T),
 'com.google.android.leanbacklauncher.recommendations': ('Рекомендации лаунчера', A),
 'com.tcl.bi': ('Аналитика TCL', T),
 'com.xm.webcontent': ('Веб-контент Xiaomi', A),
 'tv.samba.ssm': ('Samba TV', R),
 'tv.samba.ssm.ui': ('Samba TV (интерфейс)', R),
 'com.tcl.logkit': ('Логи TCL', T),
 'com.tcl.channelplus': ('Каналы TCL Channel+', A),
 'com.android.health.connect.backuprestore': ('Health Connect (резерв)', 'Сервис здоровья для телефонов, на ТВ не нужен'),
 'com.android.healthconnect.controller': ('Health Connect', 'Сервис здоровья для телефонов, на ТВ не нужен'),
 'com.xiaomi.statistic': ('Статистика Xiaomi', T),
 'com.xiaomi.floatingframe': ('Рекламное окно Xiaomi', A),
 'com.netflix.ninja': ('Netflix', F),
 'tv.anoki.acr.anokiacroptin': ('Anoki ACR', R),
 'tv.anoki.acr.controller': ('Anoki ACR', R),
 'com.android.dreams.basic': ('Простая заставка', F),
 'com.mitv.tvhome.michannel': ('Подборки Mi', A),
 'com.mitv.tvhome.mitvplus': ('Mi TV+ (рекламные каналы)', A),
 'com.sonyericsson.idd.agent': ('Сбор данных Sony', T),
 'com.google.android.youtube.tv': ('YouTube', F),
 'com.disney.disneyplus': ('Disney+', F),
 'org.droidtv.candeebug': ('Отладочный сбор Philips', T),
 'org.droidtv.gel': ('Логи Philips', T),
 'com.amazon.wirelessmetrics.service': ('Метрики Wi-Fi Amazon', T),
 'com.amazon.shoptv.client': ('Amazon Shopping', A),
}

# Yandex TV and Sber (Salute TV): Russian names and verdicts from the CleanYourTV YaOS/StarOS lists
# (artel-43d1200b, sunwind-sun-led32xs305, sber-salute-tv-at30a6, sber-salute-tv-pb766). These win over ASK:
# telemetry and promo services go "remove", the owner's features stay "caution".
G='Игровой сервис, на ТВ обычно не нужен'; C='«Ускоритель»-пустышка, сам ест память'
DREAM='Заставка производителя: картинки и реклама, занимает место'
RU = {
 'com.yandex.android.advid': ('Рекламный ID Яндекса', A, 'remove'),
 'com.yandex.tv.bugreportsender': ('Отчёты об ошибках Яндекса', T, 'remove'),
 'com.yandex.prebuiltstub': ('Пустая заглушка Яндекса', 'Пустая заглушка производителя', 'remove'),
 'com.yandex.tv.daydream': ('Заставка Яндекса', DREAM, 'caution'),
 'com.yandex.tv.webplayer': ('Веб-плеер Яндекса', 'Кинопоиск и YouTube играют без него', 'caution'),
 'com.yandex.tv.alice': ('Алиса', 'Голосовой помощник: без него не работает кнопка микрофона на пульте', 'caution'),
 'com.yandex.browser.tv': ('Яндекс Браузер', F, 'caution'),
 'com.yandex.tv.music': ('Яндекс Музыка', F, 'caution'),
 'com.yandex.tv.videoplayer': ('Видеоплеер Яндекса', F, 'caution'),
 'com.yandex.tv.input.efir': ('Эфир (онлайн-каналы Яндекса)', 'Онлайн-каналы без антенны: HDMI и антенна работают и без него', 'caution'),
 'com.yandex.tv.ytplayer': ('YouTube от Яндекса', F, 'caution'),
 'com.cultraview.newfilemanager': ('Файлы и USB-плеер', F, 'caution'),
 'ru.sberdevices.survey': ('Опросы Сбера', T, 'remove'),
 'ru.sberdevices.bugreporter': ('Отчёты об ошибках Сбера', T, 'remove'),
 'ru.sberdevices.starcleaner': ('Очистка памяти Сбера', C, 'remove'),
 'ru.sberdevices.openbeta': ('Бета-программа Сбера', 'Бета-версии прошивки, обычному владельцу не нужны', 'remove'),
 'ru.sberdevices.smarthome.promo': ('Реклама умного дома Сбера', A, 'remove'),
 'ru.sberdevices.subscriptions': ('СберПрайм (подписки)', A, 'caution'),
 'ru.sberdevices.music': ('Звук (музыка Сбера)', F, 'caution'),
 'ru.sberdevices.starlivetv': ('Онлайн-каналы Сбера', F, 'caution'),
 'ru.sberdevices.startube': ('YouTube от Сбера', F, 'caution'),
 'ru.sberdevices.videos': ('Видео (каталог Сбера)', F, 'caution'),
 'ru.sberdevices.sberplay': ('SberPlay (игры)', G, 'caution'),
 'ru.sberdevices.gamepad.service': ('Геймпад Сбера', G, 'caution'),
 'ru.sberdevices.starkidsroom.prod': ('Детская комната', F, 'caution'),
 'ru.sberdevices.parentcontrol': ('Родительский контроль Сбера', F, 'caution'),
 'ru.sberdevices.starprofile': ('Профили Сбера', F, 'caution'),
 'ru.sberdevices.starbrowser': ('Браузер Салют', F, 'caution'),
 'ru.sberdevices.tv': ('Настройка провайдеров ТВ', 'Программа передач для онлайн-каналов: HDMI и антенна работают без неё', 'caution'),
 'ru.sberdevices.starscreensaver': ('Заставка Сбера', DREAM, 'caution'),
 'ru.sberdevices.huaweicast': ('Huawei Cast+', F, 'caution'),
 'com.salute.star': ('Умный дом Сбера', F, 'caution'),
 'com.maxhub.screenshare.server.tv': ('MHshare (трансляция экрана)', F, 'caution'),
 'com.screenshare.platform': ('ScreenShare (для MHshare)', F, 'caution'),
 'ru.more.play': ('Okko', F, 'caution'),
 'ru.mts.mtstv': ('KION', F, 'caution'),
 'ru.ivi.client': ('Иви', F, 'caution'),
 'com.vgtrk.smotrim': ('Смотрим', F, 'caution'),
 'ru.tv1.android.tv': ('Первый канал', F, 'caution'),
 'tv.lfstrm.smotreshka_stb': ('Смотрёшка', F, 'caution'),
 'com.vk.tv': ('VK Видео', F, 'caution'),
}

# Checked against couch-tv's privacy list (tv-home/tools/privacy-list.txt, MIT, sources in its docs/PRIVACY.md).
# Fire TV tracking and ad services: ASK makes every "amazon" package caution, these are pure telemetry/ads.
ACRN='Следит, что вы смотрите (ACR)'
RU.update({
 'com.amazon.tv.acr': ('Распознавание контента Amazon', ACRN, 'remove'),
 'com.amazon.hybridadidservice': ('Рекламный ID Amazon', A, 'remove'),
 'com.amazon.privacypassservice': ('Privacy Pass Amazon (рекламные токены)', A, 'remove'),
 'com.amazon.hedwig': ('Рекламные каналы Fire TV', A, 'remove'),
 'com.amazon.sneakpeek': ('Sneak Peek (реклама на главном)', A, 'remove'),
 'com.amazon.kso.blackbird': ('Спецпредложения Amazon', A, 'remove'),
 'com.amazon.wirelessmetrics.service': ('Метрики Wi-Fi Amazon', T, 'remove'),
 'com.amazon.perfcollection': ('Сбор данных о работе Amazon', T, 'remove'),
 'com.amazon.tv.fw.metrics': ('Метрики прошивки Fire TV', T, 'remove'),
 'com.amazon.dp.logger': ('Журнал устройства Amazon', T, 'remove'),
 'com.amazon.logan': ('Журналы Amazon', T, 'remove'),
 'com.amazon.neo.minerva.logcat': ('Сбор системных журналов Amazon', T, 'remove'),
 'com.amazon.ceviche': ('Метрики Amazon (Ceviche)', T, 'remove'),
 'com.amazon.spiderpork': ('Метрики Amazon (Spiderpork)', T, 'remove'),
 # Sony and Xiaomi promo/ad services missing from CleanYourTV
 'com.sony.dtv.promos': ('Промо Sony', A, 'remove'),
 'com.sony.dtv.sonyselect': ('Sony Select (витрина приложений)', A, 'remove'),
 'com.sony.dtv.notificationcenter': ('Уведомления Sony', 'Присылает промо-уведомления, но через него идут и системные', 'caution'),
 'com.miui.msa.global': ('Рекламный сервис Xiaomi (MSA)', A, 'remove'),
 # Widely removed, but couch-tv keeps them for good reasons: not for the automatic clean
 'com.google.android.tvrecommendations': ('Рекомендации Google',
     'Рекомендации на главном. На Google TV через него идёт ряд «Продолжить просмотр»', 'caution'),
 'com.google.android.partnersetup': ('Настройка партнёров Google',
     'Ставит партнёрские приложения, но нужен при настройке ТВ после сброса', 'caution'),
 'com.android.adservices.api': ('Рекламные сервисы Android',
     'Модуль самой системы Android: рекламу не показывает, лучше не трогать', 'caution'),
 'com.android.ondevicepersonalization.services': ('Персонализация рекламы',
     'Модуль самой системы Android: рекламу не показывает, лучше не трогать', 'caution'),
 'com.android.federatedcompute.services': ('Обучение рекламы на устройстве',
     'Модуль самой системы Android: рекламу не показывает, лучше не трогать', 'caution'),
 # Chinese MIUI TV (MiTV-MFTR0 reflashed to Russian, Android 11): stuck on the boot logo after only this
 # one was disabled (2026-11-21). It is the OneTrack host PatchWall itself installs; CleanYourTV's
 # Android 11 MFTR0 list leaves it out. Not for the automatic clean.
 'com.miui.analytics': ('Аналитика MIUI (OneTrack)',
     'Сбор статистики, но на китайских Xiaomi без него может не загрузиться главный экран', 'caution'),
})

# Plain words for what an app does and what stops working (owners said the generic lines tell them nothing).
# Exact packages first, then name patterns; both only replace the generic reasons.
STREAM='Онлайн-кинотеатр: уберите, если нет подписки и не смотрите'
MUSIC='Музыка: уберите, если не слушаете музыку на телевизоре'
SAVER='Заставка, когда ТВ простаивает. Без неё будет просто тёмный экран'
CAST='Трансляция с телефона на ТВ: уберите, если не выводите видео с телефона'
YT='YouTube: уберите, только если смотрите его в другом приложении'
BROWSER='Браузер: уберите, если не открываете сайты на телевизоре'
PLAYER='Плеер для видео: если после удаления что-то перестанет играть, верните его в «Истории»'
GALLERY='Фото и видео с флешки: уберите, если не смотрите их на ТВ'
ALEXA='Часть Alexa: уберите, если не пользуетесь голосовым помощником Amazon'
VOICE='Голосовой помощник: без него не работает кнопка микрофона на пульте'
CAMERA='Камера: на телевизоре без камеры не нужна'
DESCR = {
 'com.google.android.videos': STREAM, 'com.amazon.amazonvideo.livingroom': STREAM, 'com.netflix.ninja': STREAM,
 'com.disney.disneyplus': STREAM, 'ru.more.play': STREAM, 'ru.mts.mtstv': STREAM, 'ru.ivi.client': STREAM,
 'tv.lfstrm.smotreshka_stb': STREAM,
 'com.google.android.youtube.tvmusic': MUSIC, 'com.spotify.tv.android': MUSIC, 'com.xiaomi.mimusic2': MUSIC,
 'com.yandex.tv.music': MUSIC, 'ru.sberdevices.music': MUSIC,
 'com.google.android.backdrop': SAVER, 'com.google.android.apps.tv.dreamx': SAVER, 'com.android.dreams.basic': SAVER,
 'com.mitv.dream': SAVER,
 'com.google.android.youtube.tv': YT, 'com.yandex.tv.ytplayer': YT, 'ru.sberdevices.startube': YT,
 'com.yandex.browser.tv': BROWSER, 'ru.sberdevices.starbrowser': BROWSER,
 'com.yandex.tv.videoplayer': PLAYER, 'com.cultraview.newfilemanager': 'Файлы и плеер для флешки: уберите, если не смотрите видео с USB',
 'com.mitv.gallery': GALLERY,
 'com.tcl.assistant': VOICE,
 'com.android.companiondevicemanager': 'Подключение часов и других гаджетов к ТВ; почти никому не нужно',
 'com.android.pacprocessor': 'Автонастройка прокси по PAC-файлу: нужна только в офисных сетях',
 'com.cvte.tv.ucservice': 'Аккаунт производителя (CVTE): нужен только для его фирменных сервисов',
 'com.android.camera2': CAMERA, 'com.android.cameraextensions': CAMERA,
 'com.google.android.syncadapters.contacts': 'Синхронизация контактов: на ТВ бесполезна',
 'com.android.managedprovisioning': 'Корпоративное управление устройством: дома не нужно',
 'com.android.cellbroadcastreceiver': 'Экстренные оповещения через сотовую сеть: на ТВ без SIM-карты не работают',
 'com.android.cellbroadcastservice': 'Экстренные оповещения через сотовую сеть: на ТВ без SIM-карты не работают',
}
DESCR_RX = [(re.compile(a, re.I), b) for a, b in [
 (r'netflix|primevideo|amazonvideo|disney|hulu|(?<![a-z])hbo|okko|kinopoisk|ivi\.client|kion', STREAM),
 (r'miracast|dlna|screenshare|screen_?mirror|airplay|\.dmr\b|(?<!broad)cast(?!le)', CAST),
 (r'dream|screensaver|backdrop', SAVER),
 (r'hbbtv', 'HbbTV: интерактивные кнопки эфирных каналов. Сами каналы работают и без него'),
 (r'alexa', ALEXA),
 (r'(?<!media)(?<!file)browser', BROWSER),
 (r'gallery|album', GALLERY),
 (r'camera', CAMERA),
 (r'(?<!sound)(?<!audio)music(?!fx)|spotify', MUSIC),
 (r'videoplayer|movieplayer|mediaplayer', PLAYER),
]]
GENERIC = {DEFAULT_REASON, F}

LAUNCHER_OK = re.compile(r'launcher\.(recommendations|partnerwidget|customizer)$', re.I)
def protected(p):
    # any brand's home screen stays: we clean, we don't replace the TV's launcher here
    if re.search(r'launcher', p, re.I) and not LAUNCHER_OK.search(p): return True
    return any(r.search(p) for r in PROT)

active = collections.Counter(); commented = collections.Counter()
comments = collections.defaultdict(collections.Counter); sections = collections.defaultdict(collections.Counter)
files = sorted(os.listdir('ex'))
for f in files:
    section = ''; prev_blank = True
    for raw in open(os.path.join('ex', f), encoding='utf-8', errors='replace'):
        line = raw.strip()
        if not line: prev_blank = True; continue
        m = act_re.match(line)
        if m:
            p = m.group(1); active[p] += 1
            if m.group(2): comments[p][m.group(2).strip()] += 1
            if section: sections[p][section] += 1
            prev_blank = False; continue
        m = com_re.match(line)
        if m:
            commented[m.group(1)] += 1; prev_blank = False; continue
        if line.startswith('#'):
            t = line.lstrip('#').strip()
            if prev_blank or not section: section = t
            prev_blank = False

curated = {e['packageName']: e for e in json.load(open(sys.argv[1]))}
out = []
for p, a in active.items():
    if protected(p): continue
    c = commented[p]
    votes = collections.Counter()
    for txt, n in list(sections[p].items()) + list(comments[p].items()) + [(p, 1)]:
        cat = next((r for rx, r in CATS if rx.search(txt)), None)
        if cat: votes[cat] += n
    reason = votes.most_common(1)[0][0] if votes else DEFAULT_REASON
    ask = bool(ASK.search(p.lower()))
    if ask: verdict = 'caution'
    elif a >= 3 and a >= 2 * c: verdict = 'remove'
    else: verdict = 'caution'
    lbl = None
    if comments[p]: lbl = label_from_comment(comments[p].most_common(1)[0][0])
    lbl = lbl or pretty(p)
    if ask and reason == DEFAULT_REASON: reason = F
    if p in OVERRIDES:
        lbl, reason = OVERRIDES[p]
    out.append({'packageName': p, 'label': lbl, 'verdict': verdict,
                'reason': f'{reason} · скрывают в {a} из {len(files)} проверенных списков', 'sizeMb': 0, 'lists': a})
# keep curated entries that were not in CYT (and not protected); curated label wins
have = {e['packageName']: e for e in out}
for p, e in curated.items():
    if protected(p): continue
    if p in have:
        if p not in OVERRIDES: have[p]['label'] = e.get('label') or have[p]['label']
    else:
        out.append({'packageName': p, 'label': e.get('label') or pretty(p), 'verdict': e['verdict'] if e['verdict'] in ('remove','caution') else 'caution',
                    'reason': DEFAULT_REASON, 'sizeMb': 0, 'lists': 0})
have = {e['packageName']: e for e in out}
for p, (lbl, reason, verdict) in RU.items():
    if protected(p): continue
    e = have.get(p)
    if e is None:
        e = {'packageName': p, 'sizeMb': 0, 'lists': 0}
        out.append(e); have[p] = e
    n = e['lists'] or active[p]
    e.update(label=lbl, verdict=verdict,
             reason=f'{reason} · скрывают в {n} из {len(files)} проверенных списков' if n else reason, lists=n)
for e in out:
    base, _, rest = e['reason'].partition(' · ')
    if base not in GENERIC: continue
    p = e['packageName']
    new = DESCR.get(p) or next((r for rx, r in DESCR_RX if rx.search(p) or rx.search(e['label'])), None)
    if new: e['reason'] = new + (' · ' + rest if rest else '')
out.sort(key=lambda e: (-e['lists'], e['packageName']))
import datetime
# Phones download this file from GitHub and use it if "version" is higher:
# bump it on every change (yyyymmddNN).
version = int(os.environ.get('DB_VERSION') or datetime.date.today().strftime('%Y%m%d') + '01')
doc = {'version': version, 'generated': datetime.date.today().isoformat(),
       'source': 'CleanYourTV examples (MIT) + TVCleanzer protection',
       'count': len(out), 'packages': out}
json.dump(doc, open('packages.json', 'w'), ensure_ascii=False, separators=(',', ':'))
v = collections.Counter(e['verdict'] for e in out)
print(len(files), 'lists ->', len(out), 'packages', dict(v), os.path.getsize('packages.json')//1024, 'KB')
for e in out[:25]: print(e['lists'], e['verdict'], e['packageName'], '|', e['label'], '|', e['reason'][:60])
