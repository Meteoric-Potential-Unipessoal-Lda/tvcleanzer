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
