/// Fine settings of TVCleanzer Launcher on the TV (launcher 0.4+).
/// Values match Prefs.ANIM_* / Prefs.TILES_* in launcher/src.
class LauncherLook {
  /// 0 full, 1 soft, 2 off.
  final int anim;
  /// Focus ring in the skin's accent colour instead of white.
  final bool ringAccent;
  /// 0 compact (7 per row), 1 normal (6), 2 large (5).
  final int tiles;
  /// How much the own photo is darkened, percent 0–90.
  final int wallDim;
  /// Slowly drifting accent glow (skins without a photo).
  final bool ambient;
  final bool clock24;
  /// App names always under tiles (otherwise only on the focused one).
  final bool labels;
  /// HDMI/inputs row: 0 above favourites, 1 under all apps, 2 hidden (launcher 0.6+).
  final int inputs;
  /// Favourites: 0 one scrolling row, 4/5/6 a grid with that many per row (launcher 0.11+).
  final int favCols;
  /// Home screen look (launcher 0.7+): 0 tiles, 1 big clock with a dock, 2 «Витрина» (0.32+).
  final int style;
  /// Tile pictures (launcher 0.32+): 0 auto (icons in the dock and «Витрина», TV banners in
  /// the tiles), 1 the apps' own icons everywhere, 2 TV banners wherever an app has one,
  /// 3 small icons at their own size on the cards (launcher 0.48+).
  final int icons;
  /// «Витрина»: the focused app's name in large letters above the tiles (launcher 0.33+).
  final bool heroTitle;
  /// RAM pill on the TV home screen that frees memory when pressed (launcher 0.36+).
  final bool memPill;
  /// Only the gear up top, opening the TV's settings (hold: the launcher's) (launcher 0.49+).
  final bool cleanBar;
  /// Theme changes by itself (launcher 0.48+): 0 off, 1 every hour, 2 every day.
  final int skinAuto;
  /// Live background: seconds per drift, 0 = by the animation setting (launcher 0.48+).
  final int ambientSec;
  /// Clock style: 0 left, 1 centre.
  final int clockPos;
  /// Clock size, percent (60–180).
  final int clockSize;
  /// Clock font: 0 thin, 1 light, 2 regular, 3 condensed, 4 bold.
  final int clockFont;
  /// Weather on the home screen: city name ('' = off) and its coordinates.
  final String weatherCity;
  final double lat;
  final double lon;
  /// Tiles style: the app grid starts on the second screen (launcher 0.20+).
  final bool appsBelow;
  /// Top bar (launcher 0.61+): the «Добрый вечер» line, the clock's size (0 large, 1 medium,
  /// 2 small) and the date and weather on one line next to the clock.
  final bool greeting;
  final int barClock;
  final bool oneLine;
  /// Icon shape where the launcher draws icons (launcher 0.55+, settable from the phone 0.62+):
  /// 0 rounded squares, 1 circles. Small icons are always round, TV banners have no shape.
  final int iconShape;
  /// Bluetooth pill in the top bar: on/off, what is connected, OK switches it (launcher 0.63+).
  final bool btPill;
  /// Top bar (launcher 0.68+): 0 words, 1 round icons, 2 small icons in the corner (default).
  final int barStyle;
  /// One row of favourites (tiles home, 0.68+): 0 full width, 1 as wide as its tiles on the
  /// left (default), 2 in the middle.
  final int favAlign;
  /// Glass under the clock, date and weather (launcher 0.68+).
  final bool clockGlass;
  /// Every glass on the home screen: 0 light, 1 transparent, 2 dark (launcher 0.72+; before
  /// that only the favourites shelf, TV-side only).
  final int shelf;
  /// No names under the home screen's icons (launcher 0.83+): the dock gets lower.
  final bool noLabels;
  /// No frame round the selected app, it only grows (launcher 0.89+).
  final bool ringOff;
  /// A soft halo in the app's colour round the selected app (launcher 0.92+).
  final bool ringGlow;

  /// launcher 1.23: «Точка» — a blue dot beside the selected app
  final bool ringDot;
  /// The memory numbers beside the memory icon while it is selected (launcher 0.99+).
  final bool memLabel;

  /// launcher 1.22: clock, date and weather on the home screen
  final bool showClock;

  const LauncherLook({
    this.anim = 0,
    this.ringAccent = false,
    this.tiles = 1,
    this.wallDim = 40,
    this.ambient = true,
    this.clock24 = true,
    this.labels = false,
    this.inputs = 0,
    this.favCols = 0,
    this.style = 0,
    this.clockPos = 1,
    this.clockSize = 100,
    this.clockFont = 0,
    this.weatherCity = '',
    this.lat = 0,
    this.lon = 0,
    this.appsBelow = false,
    this.icons = 0,
    this.heroTitle = true,
    this.memPill = true,
    this.cleanBar = false,
    this.skinAuto = 0,
    this.ambientSec = 0,
    this.greeting = true,
    this.barClock = 0,
    this.oneLine = false,
    this.iconShape = 0,
    this.btPill = true,
    this.barStyle = 2,
    this.favAlign = 1,
    this.clockGlass = false,
    this.shelf = 0,
    this.noLabels = false,
    this.ringOff = false,
    this.ringGlow = false,
    this.ringDot = false,
    this.memLabel = true,
    this.showClock = true,
  });

  LauncherLook copyWith({int? anim, bool? ringAccent, int? tiles, int? wallDim,
          bool? ambient, bool? clock24, bool? labels, int? inputs, int? favCols, int? style, int? clockPos,
          int? clockSize, int? clockFont, String? weatherCity, double? lat, double? lon, bool? appsBelow, int? icons, bool? heroTitle, bool? memPill, bool? cleanBar, int? skinAuto, int? ambientSec,
          bool? greeting, int? barClock, bool? oneLine, int? iconShape, bool? btPill,
          int? barStyle, int? favAlign, bool? clockGlass, int? shelf, bool? noLabels, bool? ringOff, bool? ringGlow, bool? ringDot, bool? memLabel, bool? showClock}) =>
      LauncherLook(
        anim: anim ?? this.anim,
        ringAccent: ringAccent ?? this.ringAccent,
        tiles: tiles ?? this.tiles,
        wallDim: wallDim ?? this.wallDim,
        ambient: ambient ?? this.ambient,
        clock24: clock24 ?? this.clock24,
        labels: labels ?? this.labels,
        inputs: inputs ?? this.inputs,
        favCols: favCols ?? this.favCols,
        style: style ?? this.style,
        clockPos: clockPos ?? this.clockPos,
        clockSize: clockSize ?? this.clockSize,
        clockFont: clockFont ?? this.clockFont,
        weatherCity: weatherCity ?? this.weatherCity,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        appsBelow: appsBelow ?? this.appsBelow,
        icons: icons ?? this.icons,
        heroTitle: heroTitle ?? this.heroTitle,
        memPill: memPill ?? this.memPill,
        cleanBar: cleanBar ?? this.cleanBar,
        skinAuto: skinAuto ?? this.skinAuto,
        ambientSec: ambientSec ?? this.ambientSec,
        greeting: greeting ?? this.greeting,
        barClock: barClock ?? this.barClock,
        oneLine: oneLine ?? this.oneLine,
        iconShape: iconShape ?? this.iconShape,
        btPill: btPill ?? this.btPill,
        barStyle: barStyle ?? this.barStyle,
        favAlign: favAlign ?? this.favAlign,
        clockGlass: clockGlass ?? this.clockGlass,
        shelf: shelf ?? this.shelf,
        noLabels: noLabels ?? this.noLabels,
        ringOff: ringOff ?? this.ringOff,
        ringGlow: ringGlow ?? this.ringGlow,
        ringDot: ringDot ?? this.ringDot,
        memLabel: memLabel ?? this.memLabel,
        showClock: showClock ?? this.showClock,
      );

  /// Extras for `am broadcast … com.tvcleanzer.launcher.APPLY`.
  String get extras => '--ei anim $anim --ez ringAccent $ringAccent --ei tiles $tiles '
      '--ei wallDim $wallDim --ez ambient $ambient --ez clock24 $clock24 --ez labels $labels '
      '--ei inputs $inputs --ei favCols $favCols --ei style $style --ei clockPos $clockPos --ei clockSize $clockSize '
      '--ei clockFont $clockFont --ez appsBelow $appsBelow --ei icons $icons --ez heroTitle $heroTitle --ez memPill $memPill --ez cleanBar $cleanBar --ei skinAuto $skinAuto --ei ambientSec $ambientSec --ez greeting $greeting --ei barClock $barClock --ez oneLine $oneLine --ei iconShape $iconShape --ez btPill $btPill --ei barStyle $barStyle --ei favAlign $favAlign --ez clockGlass $clockGlass --ei shelf $shelf --ez noLabels $noLabels --ez ringOff $ringOff --ez ringGlow $ringGlow --ez ringDot $ringDot --ez memLabel $memLabel --ez showClock $showClock --es weatherCity ${_q(weatherCity)}'
      '${weatherCity.isEmpty ? '' : ' --ef lat ${lat.toStringAsFixed(4)} --ef lon ${lon.toStringAsFixed(4)}'}';

  /// Single-quoted for the TV's shell (city names may have spaces or apostrophes).
  static String _q(String s) => s.isEmpty ? '""' : "'${s.replaceAll("'", "'\\''")}'";

  Map<String, Object> toJson() => {
        'anim': anim, 'ringAccent': ringAccent, 'tiles': tiles, 'wallDim': wallDim,
        'ambient': ambient, 'clock24': clock24, 'labels': labels, 'inputs': inputs, 'favCols': favCols,
        'style': style, 'clockPos': clockPos, 'clockSize': clockSize, 'clockFont': clockFont,
        'weatherCity': weatherCity, 'lat': lat, 'lon': lon, 'appsBelow': appsBelow, 'icons': icons, 'heroTitle': heroTitle, 'memPill': memPill,
        'cleanBar': cleanBar, 'skinAuto': skinAuto, 'ambientSec': ambientSec,
        'greeting': greeting, 'barClock': barClock, 'oneLine': oneLine, 'iconShape': iconShape, 'btPill': btPill,
        'barStyle': barStyle, 'favAlign': favAlign, 'clockGlass': clockGlass, 'shelf': shelf,
        'noLabels': noLabels,
        'ringOff': ringOff,
        'ringGlow': ringGlow,
        'ringDot': ringDot,
        'memLabel': memLabel,
        'showClock': showClock,
      };

  static int _i(Object? v, int def, int lo, int hi) =>
      (v is num ? v.toInt() : int.tryParse('$v') ?? def).clamp(lo, hi);
  static bool _b(Object? v, bool def) =>
      v is bool ? v : (v == null ? def : '$v' == '1' || '$v' == 'true');

  /// From saved JSON or from the launcher's settings rows (strings).
  factory LauncherLook.fromMap(Map<String, Object?> m) => LauncherLook(
        anim: _i(m['anim'], 0, 0, 2),
        ringAccent: _b(m['ringAccent'], false),
        tiles: _i(m['tiles'], 1, 0, 2),
        wallDim: _i(m['wallDim'], 40, 0, 90),
        ambient: _b(m['ambient'], true),
        clock24: _b(m['clock24'], true),
        labels: _b(m['labels'], false),
        inputs: _i(m['inputs'], 0, 0, 2),
        favCols: const [4, 5, 6].contains(_i(m['favCols'], 0, 0, 6)) ? _i(m['favCols'], 0, 0, 6) : 0,
        style: _i(m['style'], 0, 0, 2),
        clockPos: _i(m['clockPos'], 1, 0, 1),
        clockSize: _i(m['clockSize'], 100, 60, 180),
        clockFont: _i(m['clockFont'], 0, 0, 4),
        weatherCity: m['weatherCity'] == null || '${m['weatherCity']}' == '-' ? '' : '${m['weatherCity']}',
        lat: double.tryParse('${m['lat'] ?? ''}') ?? 0,
        lon: double.tryParse('${m['lon'] ?? ''}') ?? 0,
        appsBelow: _b(m['appsBelow'], false),
        icons: _i(m['icons'], 0, 0, 3),
        heroTitle: _b(m['heroTitle'], true),
        memPill: _b(m['memPill'], true),
        cleanBar: _b(m['cleanBar'], false),
        skinAuto: _i(m['skinAuto'], 0, 0, 2),
        ambientSec: _i(m['ambientSec'], 0, 0, 300),
        greeting: _b(m['greeting'], true),
        barClock: _i(m['barClock'], 0, 0, 2),
        oneLine: _b(m['oneLine'], false),
        iconShape: _i(m['iconShape'], 0, 0, 1),
        btPill: _b(m['btPill'], true),
        barStyle: _i(m['barStyle'], 2, 0, 2),
        favAlign: _i(m['favAlign'], 1, 0, 2),
        clockGlass: _b(m['clockGlass'], false),
        shelf: _i(m['shelf'], 0, 0, 2),
        noLabels: _b(m['noLabels'], false),
        ringOff: _b(m['ringOff'], false),
        ringGlow: _b(m['ringGlow'], false),
        ringDot: _b(m['ringDot'], false),
        memLabel: _b(m['memLabel'], true),
        showClock: _b(m['showClock'], true),
      );
}
