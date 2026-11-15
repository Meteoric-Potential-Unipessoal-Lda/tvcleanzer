import 'dart:convert';
import 'dart:io';

/// A place for the weather on the TV's home screen.
class GeoPlace {
  final String name;
  final String region;   // "Оренбургская область, Россия"
  final double lat;
  final double lon;
  const GeoPlace(this.name, this.region, this.lat, this.lon);
}

/// City search for the launcher's weather: Open-Meteo geocoding (free, no key).
/// Only the typed city name is sent; nothing about the user or the phone.
class Geo {
  Geo._();

  static Future<List<GeoPlace>> search(String query, {String lang = 'ru'}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search',
          {'name': q, 'count': '6', 'language': lang, 'format': 'json'});
      final res = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final list = (body['results'] as List?) ?? const [];
      return [
        for (final r in list.cast<Map<String, dynamic>>())
          GeoPlace(
            '${r['name'] ?? ''}',
            [r['admin1'], r['country']].whereType<String>().where((s) => s.isNotEmpty).join(', '),
            (r['latitude'] as num).toDouble(),
            (r['longitude'] as num).toDouble(),
          ),
      ];
    } finally {
      client.close(force: true);
    }
  }
}
