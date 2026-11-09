import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The package database: bundled with the app, refreshed from GitHub.
///
/// The app ships assets/packages.json. On start it quietly downloads the same
/// file from the main branch; if that copy has a higher "version" it is saved
/// and used from then on. So fixing the database = committing packages.json.
/// Whatever the database says, Protection and the TV's own HOME check still
/// decide what may never be removed.
class PackageDb {
  PackageDb._();

  static const remoteUrl =
      'https://raw.githubusercontent.com/Meteoric-Potential-Unipessoal-Lda/tvcleanzer/main/assets/packages.json';
  static const _fileName = 'packages_remote.json';

  /// Version and size of the database in use (for the help sheet).
  static int version = 0;
  static int count = 0;

  /// Newest of bundled vs downloaded.
  static Future<List<Map<String, dynamic>>> load() async {
    final bundled = _parse(await rootBundle.loadString('assets/packages.json'));
    var best = bundled;
    try {
      final f = await _file();
      if (await f.exists()) {
        final cached = _parse(await f.readAsString());
        if (cached != null && (best == null || cached.$1 > best.$1)) best = cached;
      }
    } catch (_) {
      // broken cache: the bundled copy is fine
    }
    version = best?.$1 ?? 0;
    count = best?.$2.length ?? 0;
    return best?.$2 ?? const [];
  }

  /// Downloads the newest database. Returns true if a newer one was saved.
  static Future<bool> refresh() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(remoteUrl));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return false;
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      final remote = _parse(body);
      if (remote == null || remote.$2.length < 50) return false; // sanity check
      await load(); // sets [version] to the current best
      if (remote.$1 <= version) return false;
      await (await _file()).writeAsString(body, flush: true);
      version = remote.$1;
      count = remote.$2.length;
      return true;
    } catch (_) {
      return false; // offline or GitHub unreachable: keep what we have
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Accepts {version, packages:[...]} or a bare list (old format, version 0).
  static (int, List<Map<String, dynamic>>)? _parse(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is List) return (0, d.cast<Map<String, dynamic>>());
      if (d is Map<String, dynamic> && d['packages'] is List) {
        return ((d['version'] as num?)?.toInt() ?? 0,
            (d['packages'] as List).cast<Map<String, dynamic>>());
      }
    } catch (_) {}
    return null;
  }
}
