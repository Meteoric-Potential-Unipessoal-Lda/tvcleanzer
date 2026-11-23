import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tv_device.dart';
import '../services/adb_package_manager.dart';
import '../services/app_log.dart';

/// One finished clean: what was hidden on which TV. Kept on the phone so the
/// user can bring the apps back at any time from the History tab.
class CleanRecord {
  final String id;
  final String tvIp;
  final String tvName;
  final List<String> packages;
  final Map<String, String> labels; // packageName -> human name
  final int savedMb;
  final DateTime date;
  final bool restored;
  /// 'clean' (apps hidden) or 'boost' (animations + memory/cache).
  final String kind;
  /// boost: previous global settings to put back (key -> old value).
  final Map<String, String> settings;
  /// boost: free RAM before/after and cache freed, for the card.
  final int ramBeforeMb;
  final int ramAfterMb;
  final int cacheFreedMb;

  bool get isBoost => kind == 'boost';
  bool get canRestore => !restored && (isBoost ? settings.isNotEmpty : packages.isNotEmpty);

  const CleanRecord({
    required this.id,
    required this.tvIp,
    required this.tvName,
    required this.packages,
    required this.labels,
    required this.savedMb,
    required this.date,
    this.restored = false,
    this.kind = 'clean',
    this.settings = const {},
    this.ramBeforeMb = 0,
    this.ramAfterMb = 0,
    this.cacheFreedMb = 0,
  });

  /// Same format the clean step uses as backupId (JSON list of packages).
  String get backupId => jsonEncode(packages);

  String labelOf(String pkg) => labels[pkg] ?? pkg;

  CleanRecord copyWith({bool? restored, String? tvIp}) => CleanRecord(
        id: id,
        tvIp: tvIp ?? this.tvIp,
        tvName: tvName,
        packages: packages,
        labels: labels,
        savedMb: savedMb,
        date: date,
        restored: restored ?? this.restored,
        kind: kind,
        settings: settings,
        ramBeforeMb: ramBeforeMb,
        ramAfterMb: ramAfterMb,
        cacheFreedMb: cacheFreedMb,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'tvIp': tvIp,
        'tvName': tvName,
        'packages': packages,
        'labels': labels,
        'savedMb': savedMb,
        'date': date.toIso8601String(),
        'restored': restored,
        'kind': kind,
        'settings': settings,
        'ramBeforeMb': ramBeforeMb,
        'ramAfterMb': ramAfterMb,
        'cacheFreedMb': cacheFreedMb,
      };

  factory CleanRecord.fromJson(Map<String, dynamic> j) => CleanRecord(
        id: j['id'] as String,
        tvIp: j['tvIp'] as String,
        tvName: j['tvName'] as String? ?? j['tvIp'] as String,
        packages: (j['packages'] as List).cast<String>(),
        labels: (j['labels'] as Map? ?? const {}).map(
            (k, v) => MapEntry(k as String, v as String)),
        savedMb: (j['savedMb'] as num?)?.toInt() ?? 0,
        date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        restored: j['restored'] as bool? ?? false,
        kind: j['kind'] as String? ?? 'clean',
        settings: (j['settings'] as Map? ?? const {}).map(
            (k, v) => MapEntry(k as String, '$v')),
        ramBeforeMb: (j['ramBeforeMb'] as num?)?.toInt() ?? 0,
        ramAfterMb: (j['ramAfterMb'] as num?)?.toInt() ?? 0,
        cacheFreedMb: (j['cacheFreedMb'] as num?)?.toInt() ?? 0,
      );
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<CleanRecord>>(
        (ref) => HistoryNotifier(api: ref.read(adbServiceProvider)));

class HistoryNotifier extends StateNotifier<List<CleanRecord>> {
  HistoryNotifier({AdbPackageManager? api})
      : _api = api,
        super(const []);

  /// Reads and writes the copy kept on each TV ([AdbPackageManager.tvHistoryPath]).
  final AdbPackageManager? _api;

  /// TVs seen this run by host, so a later «Вернуть» can update that TV's copy too.
  final Map<String, TvDevice> _tvs = {};

  static String hostOf(String id) => id.contains(':') ? id.substring(0, id.lastIndexOf(':')) : id;

  /// The phone's records plus the TV's copy: records the phone lost (reinstall, APK ↔ store)
  /// come back under the TV's current address; «Вернуть» done on either side counts.
  static List<CleanRecord> merge(List<CleanRecord> phone, List<CleanRecord> fromTv, String tvId,
      {int max = _max}) {
    final byId = {for (final r in phone) r.id: r};
    for (final t in fromTv) {
      final p = byId[t.id];
      if (p == null) {
        byId[t.id] = t.copyWith(tvIp: tvId);
      } else if (t.restored && !p.restored) {
        byId[t.id] = p.copyWith(restored: true);
      }
    }
    final all = byId.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    return all.take(max).toList();
  }

  /// Brings back what the TV remembers and leaves the TV an up-to-date copy. Quiet: a TV
  /// that can't be reached just keeps its old copy.
  Future<void> syncWithTv(TvDevice tv) async {
    final api = _api;
    if (api == null || tv.isDemo) return;
    _tvs[hostOf(tv.id)] = tv;
    try {
      final fromTv = <CleanRecord>[];
      final raw = await api.readTvHistory(tv);
      if (raw != null) {
        final j = jsonDecode(raw);
        final list = j is Map ? (j['records'] as List? ?? const []) : j as List;
        for (final e in list) {
          try {
            fromTv.add(CleanRecord.fromJson((e as Map).cast<String, dynamic>()));
          } catch (_) {}
        }
      }
      final merged = merge(state, fromTv, tv.id);
      if (jsonEncode(merged.map((r) => r.toJson()).toList()) !=
          jsonEncode(state.map((r) => r.toJson()).toList())) {
        state = merged;
        await _save();
      }
      final mine = [for (final r in state) if (hostOf(r.tvIp) == hostOf(tv.id)) r.toJson()];
      if (mine.isEmpty) return;
      await api.writeTvHistory(tv, jsonEncode({'v': 1, 'model': tv.modelName, 'records': mine}));
    } catch (e) {
      AppLog.error('history copy on TV', e);
    }
  }

  /// After a change for the TV with [tvId]: its copy on the TV, if we know the TV.
  void _copyTo(String tvId) {
    final tv = _tvs[hostOf(tvId)];
    if (tv != null) syncWithTv(tv);
  }

  static const _key = 'clean_history';
  static const _max = 50;

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null) return;
      state = (jsonDecode(raw) as List)
          .map((e) => CleanRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  Future<void> addFromClean(
      TvDevice tv, List<TvPackage> selected, CleanResult result) async {
    List<String> removed;
    try {
      removed = (jsonDecode(result.backupId) as List).cast<String>();
    } catch (_) {
      return;
    }
    if (removed.isEmpty) return;
    final labels = {
      for (final p in selected)
        if (removed.contains(p.packageName)) p.packageName: p.displayName,
    };
    final rec = CleanRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      tvIp: tv.id, // "host" or "host:port"
      tvName: tv.shortName.isEmpty ? tv.ipAddress : tv.shortName,
      packages: removed,
      labels: labels,
      savedMb: result.savedMb,
      date: result.completedAt,
    );
    state = [rec, ...state].take(_max).toList();
    await _save();
    _tvs[hostOf(tv.id)] = tv;
    _copyTo(tv.id);
  }

  Future<void> addBoost(TvDevice tv, BoostResult r) async {
    final rec = CleanRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      tvIp: tv.id, // "host" or "host:port"
      tvName: tv.shortName.isEmpty ? tv.ipAddress : tv.shortName,
      packages: const [],
      labels: const {},
      savedMb: 0,
      date: r.completedAt,
      kind: 'boost',
      settings: r.oldSettings,
      ramBeforeMb: r.ramBeforeMb,
      ramAfterMb: r.ramAfterMb,
      cacheFreedMb: r.cacheFreedMb,
    );
    state = [rec, ...state].take(_max).toList();
    await _save();
    _tvs[hostOf(tv.id)] = tv;
    _copyTo(tv.id);
  }

  Future<void> markRestored(String id) async {
    state = [for (final r in state) r.id == id ? r.copyWith(restored: true) : r];
    await _save();
    for (final r in state) {
      if (r.id == id) _copyTo(r.tvIp);
    }
  }

  /// After «Вернуть всё скрытое» on the TV at [host]: its records are all put back.
  Future<void> markAllRestoredFor(String host) async {
    state = [for (final r in state) hostOf(r.tvIp) == host ? r.copyWith(restored: true) : r];
    await _save();
    _copyTo(host);
  }

  Future<void> markRestoredByBackup(String backupId) async {
    final i = state.indexWhere((r) => !r.restored && r.backupId == backupId);
    if (i >= 0) await markRestored(state[i].id);
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(state.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }
}
