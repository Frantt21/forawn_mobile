import 'dart:convert';
import 'package:http/http.dart' as http;

class DeezerService {
  static const String _baseUrl = 'https://api.deezer.com';

  /// Buscar metadatos en Deezer
  Future<List<Map<String, dynamic>>> searchMetadata(
    String title,
    String artist,
  ) async {
    // Construir query de búsqueda precisa
    final query = 'artist:"$artist" track:"$title"';
    final url = '$_baseUrl/search?q=${Uri.encodeComponent(query)}&limit=5';

    try {
      print('[DeezerService] Searching metadata: $url');
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['data'] != null && data['data'] is List) {
          return (data['data'] as List)
              .map((item) => _normalizeItem(item))
              .toList();
        }
      }
    } catch (e) {
      print('[DeezerService] Error searching metadata: $e');
    }
    return [];
  }

  /// Normalizar respuesta de Deezer al formato esperado por la app
  Map<String, dynamic> _normalizeItem(dynamic item) {
    return {
      'title': item['title'],
      'artist': item['artist']['name'],
      'album': item['album']['title'],
      // Deezer search result doesn't always have year, but we can try to find it via album details if needed.
      // For now, let's strictly follow what search gives.
      // 'year': ...
      // 'trackNumber': ...
      'albumArtUrl':
          item['album']['cover_xl'] ??
          item['album']['cover_big'] ??
          item['album']['cover_medium'],
      'source': 'Deezer',
    };
  }
}
