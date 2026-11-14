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

  const LauncherLook({
    this.anim = 0,
    this.ringAccent = false,
    this.tiles = 1,
    this.wallDim = 40,
    this.ambient = true,
    this.clock24 = true,
    this.labels = false,
  });

  LauncherLook copyWith({int? anim, bool? ringAccent, int? tiles, int? wallDim,
          bool? ambient, bool? clock24, bool? labels}) =>
      LauncherLook(
        anim: anim ?? this.anim,
        ringAccent: ringAccent ?? this.ringAccent,
        tiles: tiles ?? this.tiles,
        wallDim: wallDim ?? this.wallDim,
        ambient: ambient ?? this.ambient,
        clock24: clock24 ?? this.clock24,
        labels: labels ?? this.labels,
      );

  /// Extras for `am broadcast … com.tvcleanzer.launcher.APPLY`.
  String get extras => '--ei anim $anim --ez ringAccent $ringAccent --ei tiles $tiles '
      '--ei wallDim $wallDim --ez ambient $ambient --ez clock24 $clock24 --ez labels $labels';

  Map<String, Object> toJson() => {
        'anim': anim, 'ringAccent': ringAccent, 'tiles': tiles, 'wallDim': wallDim,
        'ambient': ambient, 'clock24': clock24, 'labels': labels,
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
      );
}
