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
P='Ставит партнёрские приложения без спроса'; D='Демо-режим для витрины магазина'; F='Функция или приложение: уберите, только если не пользуетесь'
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
    if ask and reason == DEFAULT_REASON: reason = 'Функция или приложение: уберите, только если не пользуетесь'
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
