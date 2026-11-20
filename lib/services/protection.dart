/// Packages TVCleanzer never removes, whatever the database says.
/// Ported from tv-kit (Test-Protected) plus lessons from real TVs:
/// home screens, inputs/HDMI, remote/Bluetooth, keyboards, updates,
/// Google core, setup wizards. On top of this, scan() also protects every
/// package that the TV itself reports as a HOME screen.
class Protection {
  Protection._();

  static final List<RegExp> _rules = [
    r'^android$',
    r'^com\.android\.(systemui|settings|providers\..*|shell|phone|bluetooth|packageinstaller|permissioncontroller|inputdevices|externalstorage|webview|networkstack.*|tv\.settings|tv\.remote.*|keychain|location\.fused|se|nfc|server\..*|captiveportallogin|certinstaller|documentsui|vpndialogs|wallpaperbackup|backupconfirm|proxyhandler|sharedstoragebackup|dynsystem|localtransport|statementservice|tv)$',
    r'^com\.google\.android\.(gms|gsf|gsf\.login|ext\..*|webview|packageinstaller|permissioncontroller|tv\.remote\.service|tvlauncher|apps\.tv\.launcherx|leanbacklauncher|inputmethod\..*|tts|configupdater|networkstack.*|modulemetadata|overlay\..*)$',
    r'^com\.android\.vending$',
    // Mainline modules of Android 13–14: pm refuses them ("not installed for 0", "still enabled"),
    // so they only cluttered the list with errors (Philips Google TV report).
    r'^com\.(google\.)?android\.(adservices\.api|ondevicepersonalization\.services|federatedcompute|health\.connect\.backuprestore)$',
    // Philips firmware keeps these on whatever pm says (same report).
    r'^org\.droidtv\.(ipcontrol|control4adapterservice|matter)$',
    // Live Channels: on many Android TVs (Xiaomi Mi TV 4S and others) it is the antenna/cable player
    // behind «Live TV»; without it Live TV only shows the last HDMI input (MiTV L55M5-5ARU report).
    r'^com\.google\.android\.tv$',
    r'inputmethod|keyboard|sogou|latinime|leanbackime|(^|[._])ime([._]|$)',
    r'bluetooth|(^|[._])\w*remote\w*([._]|$)|(^|[._])(rcu\w*|autopair|btmanager)([._]|$)',
    r'(^|[._])(mediatek|realtek|amlogic|rtk|mstar|hisilicon|novatek)([._]|$)',
    r'(^|[._])(tvcenter|tvplayer|livetv|playtv|tvservice|tvmanager|tvinput\w*|tis|hdmi\w*|cec|dtv\w*|tuner\w*|atv\.service)([._]|$)',
    r'^org\.droidtv\.(settings|tvsettings|tvsystemui|systemui|channels|epg|euinstallersat|euinstallertc|tvplayer|playtv)$',
    r'(^|[._])\w*(update|upgrade)\w*([._]|$)|(^|[._])f?ota([._]|$)',
    r'setupwraith|setupwizard|partnercustomizer',
    r'^mitv\.service$',
    r'^com\.mitv\.overseaservice$',
    r'vpn|proxy',
    r'webview',
    r'tclhome|smarttvhome|litehome|tvhome_master',
    r'^com\.mitv\.tvhome(\.atv)?$',
    r'^com\.amazon\.tv\.launcher$',
    r'^com\.tvcleanzer\.',
    // Projectors: optics, keystone/focus, sensors, and the vendor services behind
    // the remote and the projection settings (CleanYourTV projector lists).
    r'keystone|autokst|focus|(^|[._])tof([._]|$)|dewarp|(^|[._])ptz([._]|$)|imaging|projector|projection|screenfit|obstacle|optical|lightengine',
    r'^com\.xgimi\.(xrmservice|xgimiservice|misckey|windowsystem|uiconfiguration|tvinput|simpservice|soundermodeservice|bluetoothservice|starmirror|autoinstall|overseas\..*)$',
    r'^com\.sdmc\.(kt|service|btservice|globalkey|remotecontrolservice|keyburn|standbyserver|sdmcplatform|sdmcservicehelper|bluetoothconnect)$',
    r'^com\.zhixin\.(nebulasmart|apphelper|remoteautopair|nebulasetupwizard)$',
    r'^com\.oceanwing\.(nebulalinker|receiver)$',
    r'^com\.hysd\.',
    r'^com\.htc\.magcubicos$',
    r'^com\.softwinner\.(awsource|vis|awlivetv|tv\..*)$',
    r'^com\.android\.(ytb|nfx)$',
    r'^com\.epson\.(droidsettings|flexiblepicture|installation|warningui|bizmodeui)$',
    r'^com\.benq\.(benqnewrc|appsmanager)$',
    r'^com\.inspur\.benq\.remoterc$',
    r'^com\.droidlogic\.(tv\..*|tvinput|android\.tv)$',
    r'^com\.fengmi\.(platform|fmsettings)$',
    r'^com\.jmgo\.(hippo|autobrightness|android\.tv\..*)$',
    // Yandex TV (YaOS): home, account/system glue, settings, inputs, keyboard, remote, store/payment/player.
    // Efir (com.yandex.tv.input.efir) stays optional: HDMI and the tuner live in the vendor TV input.
    r'^com\.yandex\.tv\.(home|services.*|settings.*|setupwizard|input\.(?!efir).*|live|keyboard|vendor\.config)$',
    r'^com\.yandex\.(io\.sdk|webview|server\..*|devices\.(appstore|payment|player)|launcher\.updaterapp)$',
    r'^com\.yandex_uni\.rro\.',
    r'^ru\.yandex\.(bleremotecontrol|androidkeyboard\.tv)$',
    // Sber (Salute TV / StarOS): platform service + assistant, HDMI inputs, keyboard, WebView, settings, the
    // app catalogue (the only way apps get updated), overlays (CleanYourTV sber-salute-tv-at30a6, pb766).
    r'^ru\.sberdevices\.(services(\..*)?|assistant|tvinputs|app\..*|webview|systemui|sberdevicesservicesystem|location\..*|settings|starlauncher|starmarket|updater|tvfactoryhelper)$',
    r'^ru\.sberdevices\..*(overlay|\.rro|resources?)',
    r'^com\.sberbank\.settings$',
    // CVTE/MStar boards (Yandex, Sber, Haier, Hi, Leff…): factory menu and test tools, firmware updates, TV API.
    r'factory|(^|[._])fac([._]|$)|hisensefac|hkcfac|(^|[._])aging([._]|$)|autotest|(^|[._])burn([._]|$)|license\.at$',
    r'^com\.cvte\.tv\.(setting|api.*|tools)$',
    r'^com\.cultraview\.osupdate$',
    r'^com\.example\.upgrad$',
    // TCL Google TV: «Quick Panel» is what the remote's ⚙ and Source keys open; the shortcut menu
    // and TCL's own TV player sit behind them too (TCL C7L / Smart TV Pro owners lost both keys).
    r'^com\.tcl\.(suspension|common\.shortcutmenu|tv|sourcemenu)$',
  ].map((p) => RegExp(p, caseSensitive: false)).toList();

  static final _launcher = RegExp('launcher', caseSensitive: false);
  static final _launcherOk = RegExp(
      r'launcher\.(recommendations|partnerwidget|customizer)$',
      caseSensitive: false);

  static bool isProtected(String pkg) {
    if (_launcher.hasMatch(pkg) && !_launcherOk.hasMatch(pkg)) return true;
    for (final r in _rules) {
      if (r.hasMatch(pkg)) return true;
    }
    return false;
  }
}
