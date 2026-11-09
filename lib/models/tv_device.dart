/// Represents an Android TV found on the local network via ADB.
class TvDevice {
  final String id;          // unique identifier (IP address)
  final String name;        // TV display name
  final String brand;
  final String model;
  final String androidVer;
  final int    sdkVersion;
  final int    ramMb;
  final int    ramFreeMb;
  final String ipAddress;
  final int    port;        // ADB port (always 5555)
  final DateTime discoveredAt;

  const TvDevice({
    required this.id,
    required this.name,
    required this.brand,
    required this.model,
    required this.androidVer,
    required this.sdkVersion,
    required this.ramMb,
    required this.ramFreeMb,
    required this.ipAddress,
    required this.port,
    required this.discoveredAt,
  });

  /// Construct from an ADB connection: IP, shell-derived props, and
  /// optional CNXN props (the key=value pairs in the ADB CNXN banner).
  factory TvDevice.fromAdb({
    required String ip,
    required String brand,
    required String model,
    required String androidVer,
    int sdkVersion = 0,
    int ramMb      = 0,
    int ramFreeMb  = 0,
    Map<String, String> cnxnProps = const {},
  }) {
    final b = brand.isNotEmpty ? brand : (cnxnProps['ro.product.brand'] ?? 'TV');
    final m = model.isNotEmpty ? model : (cnxnProps['ro.product.model'] ?? 'Android TV');
    return TvDevice(
      id:          ip,
      name:        '$b $m'.trim(),
      brand:       b,
      model:       m,
      androidVer:  androidVer.isNotEmpty
                     ? androidVer
                     : (cnxnProps['ro.build.version.release'] ?? '?'),
      sdkVersion:  sdkVersion > 0
                     ? sdkVersion
                     : int.tryParse(cnxnProps['ro.build.version.sdk'] ?? '') ?? 0,
      ramMb:       ramMb,
      ramFreeMb:   ramFreeMb,
      ipAddress:   ip,
      port:        5555,
      discoveredAt: DateTime.now(),
    );
  }

  String get shortName => '$brand $model'.trim();
}

/// One package entry returned by the TV app /scan endpoint.
class TvPackage {
  final String packageName;
  final String? label;
  final int     sizeMb;
  final PackageVerdict verdict;
  final String? reason;   // why it's safe/unsafe to remove

  const TvPackage({
    required this.packageName,
    this.label,
    required this.sizeMb,
    required this.verdict,
    this.reason,
  });

  factory TvPackage.fromJson(Map<String, dynamic> j) => TvPackage(
    packageName: j['packageName'] as String,
    label:       j['label']       as String?,
    sizeMb:      (j['sizeMb'] as num?)?.toInt() ?? 0,
    verdict:     PackageVerdict.values.byName(
                   (j['verdict'] as String? ?? 'keep').toLowerCase()),
    reason:      j['reason']      as String?,
  );

  String get displayName => label?.isNotEmpty == true
      ? label!
      : packageName.split('.').last;
}

enum PackageVerdict {
  remove,   // safe to remove
  caution,  // remove with confirmation
  keep,     // should be kept
  system,   // never touch
}

/// Full scan result from the TV.
class ScanResult {
  final TvDevice device;
  final List<TvPackage> packages;
  final DateTime scannedAt;

  const ScanResult({
    required this.device,
    required this.packages,
    required this.scannedAt,
  });

  List<TvPackage> get toRemove   => packages.where((p) => p.verdict == PackageVerdict.remove).toList();
  List<TvPackage> get toCaution  => packages.where((p) => p.verdict == PackageVerdict.caution).toList();
  int get totalSaveMb            => toRemove.fold(0, (s, p) => s + p.sizeMb);
}

/// Result after a clean operation.
class CleanResult {
  final int removedCount;
  final int savedMb;
  final String backupId;
  final List<String> failedPackages;
  final DateTime completedAt;

  const CleanResult({
    required this.removedCount,
    required this.savedMb,
    required this.backupId,
    required this.failedPackages,
    required this.completedAt,
  });

  /// Parse from TV app's CleanResponse JSON (Gson camelCase).
  factory CleanResult.fromJson(Map<String, dynamic> j) {
    final results = (j['results'] as List?) ?? [];
    final failed = results
        .where((r) => (r as Map<String, dynamic>)['success'] == false)
        .map((r) => (r as Map<String, dynamic>)['packageName'] as String)
        .toList();
    return CleanResult(
      removedCount:   (j['removedCount'] as num?)?.toInt() ?? 0,
      savedMb:        (j['savedMb']      as num?)?.toInt() ?? 0,
      backupId:       j['backupId']      as String? ?? '',
      failedPackages: failed,
      completedAt:    DateTime.now(),
    );
  }
}

/// Result of "Ускорить": free RAM before/after, cache freed, previous
/// animation settings (for undo).
class BoostResult {
  final int ramTotalMb;
  final int ramBeforeMb;
  final int ramAfterMb;
  final int cacheFreedMb;
  final Map<String, String> oldSettings;
  final DateTime completedAt;

  const BoostResult({
    required this.ramTotalMb,
    required this.ramBeforeMb,
    required this.ramAfterMb,
    required this.cacheFreedMb,
    required this.oldSettings,
    required this.completedAt,
  });

  int get ramGainMb => ramAfterMb > ramBeforeMb ? ramAfterMb - ramBeforeMb : 0;
}
