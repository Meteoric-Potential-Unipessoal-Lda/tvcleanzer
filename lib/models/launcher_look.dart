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
  /// the tiles), 1 the apps' own icons everywhere, 2 TV banners wherever an app has one.
  final int icons;
  /// «Витрина»: the focused app's name in large letters above the tiles (launcher 0.33+).
  final bool heroTitle;
  /// RAM pill on the TV home screen that frees memory when pressed (launcher 0.36+).
  final bool memPill;
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
  });

  LauncherLook copyWith({int? anim, bool? ringAccent, int? tiles, int? wallDim,
          bool? ambient, bool? clock24, bool? labels, int? inputs, int? favCols, int? style, int? clockPos,
          int? clockSize, int? clockFont, String? weatherCity, double? lat, double? lon, bool? appsBelow, int? icons, bool? heroTitle, bool? memPill}) =>
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
      );

  /// Extras for `am broadcast … com.tvcleanzer.launcher.APPLY`.
  String get extras => '--ei anim $anim --ez ringAccent $ringAccent --ei tiles $tiles '
      '--ei wallDim $wallDim --ez ambient $ambient --ez clock24 $clock24 --ez labels $labels '
      '--ei inputs $inputs --ei favCols $favCols --ei style $style --ei clockPos $clockPos --ei clockSize $clockSize '
      '--ei clockFont $clockFont --ez appsBelow $appsBelow --ei icons $icons --ez heroTitle $heroTitle --ez memPill $memPill --es weatherCity ${_q(weatherCity)}'
      '${weatherCity.isEmpty ? '' : ' --ef lat ${lat.toStringAsFixed(4)} --ef lon ${lon.toStringAsFixed(4)}'}';

  /// Single-quoted for the TV's shell (city names may have spaces or apostrophes).
  static String _q(String s) => s.isEmpty ? '""' : "'${s.replaceAll("'", "'\\''")}'";

  Map<String, Object> toJson() => {
        'anim': anim, 'ringAccent': ringAccent, 'tiles': tiles, 'wallDim': wallDim,
        'ambient': ambient, 'clock24': clock24, 'labels': labels, 'inputs': inputs, 'favCols': favCols,
        'style': style, 'clockPos': clockPos, 'clockSize': clockSize, 'clockFont': clockFont,
        'weatherCity': weatherCity, 'lat': lat, 'lon': lon, 'appsBelow': appsBelow, 'icons': icons, 'heroTitle': heroTitle, 'memPill': memPill,
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
        icons: _i(m['icons'], 0, 0, 2),
        heroTitle: _b(m['heroTitle'], true),
        memPill: _b(m['memPill'], true),
      );
}
