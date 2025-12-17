// lib/services/lyrics_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Modelo para una línea de lyrics sincronizada
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});

  factory LyricLine.fromString(String line) {
    // Formato: [00:09.23] Texto de la línea
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2})\]\s*(.*)');
    final match = regex.firstMatch(line);

    if (match != null) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final centiseconds = int.parse(match.group(3)!);
      final text = match.group(4)!;

      final timestamp = Duration(
        minutes: minutes,
        seconds: seconds,
        milliseconds: centiseconds * 10,
      );

      return LyricLine(timestamp: timestamp, text: text);
    }

    // Si no coincide el formato, devolver línea sin timestamp
    return LyricLine(timestamp: Duration.zero, text: line);
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.inMilliseconds,
    'text': text,
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    timestamp: Duration(milliseconds: json['timestamp'] as int),
    text: json['text'] as String,
  );
}

/// Modelo para lyrics completos
class Lyrics {
  final String trackName;
  final String artistName;
  final String? albumName;
  final int? duration;
  final bool instrumental;
  final String plainLyrics;
  final List<LyricLine> syncedLyrics;

  Lyrics({
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
  });

  int get lineCount => syncedLyrics.length;

  Map<String, dynamic> toJson() => {
    'trackName': trackName,
    'artistName': artistName,
    'albumName': albumName,
    'duration': duration,
    'instrumental': instrumental,
    'plainLyrics': plainLyrics,
    'syncedLyrics': syncedLyrics.map((l) => l.toJson()).toList(),
  };

  factory Lyrics.fromJson(Map<String, dynamic> json) => Lyrics(
    trackName: json['trackName'] as String,
    artistName: json['artistName'] as String,
    albumName: json['albumName'] as String?,
    duration: json['duration'] as int?,
    instrumental: json['instrumental'] as bool,
    plainLyrics: json['plainLyrics'] as String,
    syncedLyrics: (json['syncedLyrics'] as List)
        .map((l) => LyricLine.fromJson(l as Map<String, dynamic>))
        .toList(),
  );
}

/// Servicio para obtener y cachear lyrics
class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  static const String _baseUrl = 'https://api.dorratz.com/v3/lyrics';
  static const String _cachePrefix = 'lyrics_cache_';

  /// Obtiene lyrics desde la API o caché
  Future<Lyrics?> fetchLyrics(String trackName, String artistName) async {
    try {
      // Crear clave de caché
      final cacheKey =
          _cachePrefix +
          '${trackName.toLowerCase()}_${artistName.toLowerCase()}'.replaceAll(
            RegExp(r'[^a-z0-9_]'),
            '_',
          );

      // Intentar obtener desde caché
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(cacheKey);

      if (cachedData != null) {
        print('[LyricsService] Using cached lyrics for: $trackName');
        final json = jsonDecode(cachedData) as Map<String, dynamic>;
        return Lyrics.fromJson(json);
      }

      // Si no está en caché, obtener desde API
      print('[LyricsService] Fetching lyrics from API for: $trackName');
      final query = Uri.encodeComponent('$trackName $artistName');
      final url = '$_baseUrl?query=$query';

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List?;

        if (results != null && results.isNotEmpty) {
          print(
            '[LyricsService] API returned ${results.length} results, searching for syncedLyrics...',
          );

          // Iterar sobre TODOS los resultados hasta encontrar uno con syncedLyrics válido
          for (int i = 0; i < results.length; i++) {
            final result = results[i] as Map<String, dynamic>;
            String? syncedLyricsRaw;

            // Intentar múltiples rutas para encontrar syncedLyrics
            // 1. Desde details.syncedLyrics
            if (result['details'] != null) {
              final details = result['details'] as Map<String, dynamic>;
              final candidate = details['syncedLyrics'];
              if (candidate is String && candidate.trim().isNotEmpty) {
                syncedLyricsRaw = candidate;
                print(
                  '[LyricsService] Found syncedLyrics in result[$i].details.syncedLyrics',
                );
              }
            }

            // 2. Directamente en result.syncedLyrics
            if (syncedLyricsRaw == null && result['syncedLyrics'] != null) {
              final candidate = result['syncedLyrics'];
              if (candidate is String && candidate.trim().isNotEmpty) {
                syncedLyricsRaw = candidate;
                print(
                  '[LyricsService] Found syncedLyrics in result[$i].syncedLyrics',
                );
              }
            }

            // 3. En result.lyrics.syncedLyrics
            if (syncedLyricsRaw == null && result['lyrics'] != null) {
              final lyricsObj = result['lyrics'] as Map<String, dynamic>;
              final candidate = lyricsObj['syncedLyrics'];
              if (candidate is String && candidate.trim().isNotEmpty) {
                syncedLyricsRaw = candidate;
                print(
                  '[LyricsService] Found syncedLyrics in result[$i].lyrics.syncedLyrics',
                );
              }
            }

            // Si encontramos syncedLyrics válido, procesarlo
            if (syncedLyricsRaw != null && syncedLyricsRaw.trim().isNotEmpty) {
              final details =
                  result['details'] as Map<String, dynamic>? ?? result;

              // Parsear synced lyrics
              final syncedLines = syncedLyricsRaw
                  .split('\n')
                  .where((line) => line.trim().isNotEmpty)
                  .map((line) => LyricLine.fromString(line))
                  .toList();

              final lyrics = Lyrics(
                trackName: details['trackName'] as String? ?? trackName,
                artistName: details['artistName'] as String? ?? artistName,
                albumName: details['albumName'] as String?,
                duration: details['duration'] as int?,
                instrumental: details['instrumental'] as bool? ?? false,
                plainLyrics: details['plainLyrics'] as String? ?? '',
                syncedLyrics: syncedLines,
              );

              // Guardar en caché
              await prefs.setString(cacheKey, jsonEncode(lyrics.toJson()));
              print(
                '[LyricsService] Lyrics cached successfully (found in result $i of ${results.length})',
              );

              return lyrics;
            }
          }

          print(
            '[LyricsService] No valid syncedLyrics found in ${results.length} results',
          );
          return null;
        } else {
          print('[LyricsService] No lyrics found in API response');
          return null;
        }
      } else {
        print('[LyricsService] API error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('[LyricsService] Error fetching lyrics: $e');
      return null;
    }
  }

  /// Limpia el caché de lyrics
  Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final lyricsKeys = keys.where((k) => k.startsWith(_cachePrefix));

      for (final key in lyricsKeys) {
        await prefs.remove(key);
      }

      print('[LyricsService] Cache cleared: ${lyricsKeys.length} entries');
    } catch (e) {
      print('[LyricsService] Error clearing cache: $e');
    }
  }

  /// Obtiene el tamaño del caché
  Future<int> getCacheSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      return keys.where((k) => k.startsWith(_cachePrefix)).length;
    } catch (e) {
      print('[LyricsService] Error getting cache size: $e');
      return 0;
    }
  }
}
