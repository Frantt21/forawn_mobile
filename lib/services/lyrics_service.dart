// lib/services/lyrics_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics_adjuster.dart';
import '../config/api_config.dart';

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

  static const String _cachePrefix = 'lyrics_cache_';

  /// Obtiene lyrics desde la API o caché
  Future<Lyrics?> fetchLyrics(
    String trackName,
    String artistName, {
    int? durationSeconds,
  }) async {
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

      // Si no está en caché, obtener desde LRCLIB API
      // Limpiar título y artista antes de buscar
      final cleanTrack = _cleanTitle(trackName);
      final cleanArtist = _cleanArtist(artistName);

      print(
        '[LyricsService] Fetching lyrics from LRCLIB for: $cleanTrack by $cleanArtist',
      );

      // Usar endpoint de búsqueda para mejor matching
      final params = {'q': '$cleanArtist $cleanTrack'};

      final uri = Uri.parse(
        '${ApiConfig.lyricsBaseUrl}/search',
      ).replace(queryParameters: params);
      print('[LyricsService] LRCLIB URL: $uri');

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List;

        if (results.isNotEmpty) {
          // Buscar el mejor match en los resultados
          for (final item in results) {
            final data = item as Map<String, dynamic>;

            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final plainLyrics = data['plainLyrics'] as String? ?? '';
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            // VALIDACIÓN ESTRICTA: Verificar título Y artista ANTES de aceptar
            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            // Calcular similitud para título (debe ser >50% o match exacto)
            final trackSimilarity = _calculateSimilarity(
              resultTrackName,
              searchTrack,
            );
            final trackExactMatch = resultTrackName == searchTrack;
            final trackMatches = trackExactMatch || trackSimilarity > 0.5;

            // Calcular similitud para artista (debe ser >50% o match exacto)
            final artistSimilarity = _calculateSimilarity(
              resultArtistName,
              searchArtist,
            );
            final artistExactMatch = resultArtistName == searchArtist;
            final artistMatches = artistExactMatch || artistSimilarity > 0.5;

            // Rechazar si NO coinciden AMBOS
            if (!trackMatches || !artistMatches) {
              print(
                '[LyricsService] Rejected: "$resultTrackName" by "$resultArtistName" '
                '(track: ${(trackSimilarity * 100).toStringAsFixed(0)}%, '
                'artist: ${(artistSimilarity * 100).toStringAsFixed(0)}%)',
              );
              continue; // Probar siguiente resultado
            }

            // Solo aceptar si tiene synced lyrics
            if (syncedLyricsRaw == null || syncedLyricsRaw.isEmpty) {
              print(
                '[LyricsService] Skipped: No synced lyrics for "$resultTrackName"',
              );
              continue;
            }

            // Lyrics válidos encontrados - parsear
            print('[LyricsService] Found synced lyrics from LRCLIB');
            print(
              '[LyricsService] Match: "$resultTrackName" by "$resultArtistName"',
            );

            // Parsear lyrics en formato LRC
            final syncedLines = syncedLyricsRaw
                .split('\n')
                .where((line) => line.trim().isNotEmpty)
                .map((line) => LyricLine.fromString(line))
                .where((line) => line.text.isNotEmpty) // Filtrar líneas vacías
                .toList();

            final lyrics = Lyrics(
              trackName: data['trackName'] as String? ?? trackName,
              artistName: data['artistName'] as String? ?? artistName,
              albumName: data['albumName'] as String?,
              duration: (data['duration'] as num?)?.toInt(),
              instrumental: data['instrumental'] as bool? ?? false,
              plainLyrics: plainLyrics,
              syncedLyrics: syncedLines,
            );

            // Guardar en caché
            await prefs.setString(cacheKey, jsonEncode(lyrics.toJson()));
            print(
              '[LyricsService] Lyrics cached successfully (${syncedLines.length} lines)',
            );

            return lyrics;
          }
        }

        // Si no se encontró ningún match válido con artista, intentar solo con título
        print(
          '[LyricsService] No results with artist, trying with title only...',
        );

        final fallbackParams = {'q': cleanTrack};
        final fallbackUri = Uri.parse(
          '${ApiConfig.lyricsBaseUrl}/search',
        ).replace(queryParameters: fallbackParams);
        print('[LyricsService] LRCLIB Fallback URL: $fallbackUri');

        final fallbackResponse = await http
            .get(fallbackUri)
            .timeout(const Duration(seconds: 10));

        if (fallbackResponse.statusCode == 200) {
          final fallbackResults = jsonDecode(fallbackResponse.body) as List;

          if (fallbackResults.isEmpty) {
            print('[LyricsService] No results from fallback search');
            return null;
          }

          // Buscar el mejor match en los resultados del fallback
          for (final item in fallbackResults) {
            final data = item as Map<String, dynamic>;

            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final plainLyrics = data['plainLyrics'] as String? ?? '';
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            // Solo verificar que el título coincida
            final searchTrack = cleanTrack.toLowerCase();

            final trackMatches =
                resultTrackName.contains(searchTrack) ||
                searchTrack.contains(resultTrackName) ||
                _calculateSimilarity(resultTrackName, searchTrack) > 0.6;

            if (!trackMatches) {
              continue;
            }

            if (syncedLyricsRaw != null && syncedLyricsRaw.isNotEmpty) {
              print(
                '[LyricsService] Found synced lyrics from LRCLIB (fallback)',
              );
              print(
                '[LyricsService] Match: "$resultTrackName" by "$resultArtistName"',
              );

              final syncedLines = syncedLyricsRaw
                  .split('\n')
                  .where((line) => line.trim().isNotEmpty)
                  .map((line) => LyricLine.fromString(line))
                  .where((line) => line.text.isNotEmpty)
                  .toList();

              final lyrics = Lyrics(
                trackName: data['trackName'] as String? ?? trackName,
                artistName: data['artistName'] as String? ?? artistName,
                albumName: data['albumName'] as String?,
                duration: (data['duration'] as num?)?.toInt(),
                instrumental: data['instrumental'] as bool? ?? false,
                plainLyrics: plainLyrics,
                syncedLyrics: syncedLines,
              );

              await prefs.setString(cacheKey, jsonEncode(lyrics.toJson()));
              print(
                '[LyricsService] Lyrics cached successfully (${syncedLines.length} lines)',
              );

              return lyrics;
            }
          }
        }

        print('[LyricsService] No valid synced lyrics found in any search');
        return null;
      } else if (response.statusCode == 404) {
        print('[LyricsService] No lyrics found in LRCLIB for: $trackName');
        return null;
      } else {
        print('[LyricsService] LRCLIB API error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('[LyricsService] Error fetching lyrics: $e');
      return null;
    }
  }

  /// Busca lyrics manualmente sin filtrado estricto
  Future<List<Lyrics>> searchLyrics(String query) async {
    try {
      final uri = Uri.parse(
        '${ApiConfig.lyricsBaseUrl}/search',
      ).replace(queryParameters: {'q': query});

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List results = jsonDecode(response.body);
        return results.map((item) {
          final data = item as Map<String, dynamic>;
          final syncedLyricsRaw = data['syncedLyrics'] as String?;
          final plainLyrics = data['plainLyrics'] as String? ?? '';

          List<LyricLine> syncedLines = [];
          if (syncedLyricsRaw != null && syncedLyricsRaw.isNotEmpty) {
            syncedLines = syncedLyricsRaw
                .split('\n')
                .where((line) => line.trim().isNotEmpty)
                .map((line) => LyricLine.fromString(line))
                .where((line) => line.text.isNotEmpty)
                .toList();
          }

          return Lyrics(
            trackName: data['trackName'] as String? ?? '',
            artistName: data['artistName'] as String? ?? '',
            albumName: data['albumName'] as String?,
            duration: (data['duration'] as num?)?.toInt(),
            instrumental: data['instrumental'] as bool? ?? false,
            plainLyrics: plainLyrics,
            syncedLyrics: syncedLines,
          );
        }).toList();
      }
      return [];
    } catch (e) {
      print('[LyricsService] Error searching lyrics: $e');
      return [];
    }
  }

  /// Guarda lyrics en caché asociados a una canción local
  Future<void> saveLyricsToCache({
    required String localTrackName,
    required String localArtistName,
    required Lyrics lyrics,
  }) async {
    try {
      final cacheKey =
          _cachePrefix +
          '${localTrackName.toLowerCase()}_${localArtistName.toLowerCase()}'
              .replaceAll(RegExp(r'[^a-z0-9_]'), '_');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cacheKey, jsonEncode(lyrics.toJson()));
      print('[LyricsService] Manual lyrics saved for $localTrackName');
    } catch (e) {
      print('[LyricsService] Error saving manual lyrics: $e');
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

  /// Ajusta lyrics con la duración real del archivo
  /// Útil cuando el audio de YouTube tiene duración diferente a la esperada
  Lyrics? adjustLyricsWithRealDuration({
    required Lyrics? lyrics,
    required Duration realDuration,
  }) {
    if (lyrics == null) return null;
    if (lyrics.duration == null) {
      print('[LyricsService] No expected duration, cannot adjust');
      return lyrics;
    }

    final expectedDuration = Duration(seconds: lyrics.duration!);

    return LyricsAdjuster.adjustLyrics(
      lyrics: lyrics,
      expectedDuration: expectedDuration,
      actualDuration: realDuration,
    );
  }

  /// Limpia el título de la canción para mejor matching
  String _cleanTitle(String title) {
    String clean = title;

    // Eliminar información de remasterización/versión
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Remaster(ed)?\s*\d*', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\(Remaster(ed)?\s*\d*\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[Remaster(ed)?\s*\d*\]', caseSensitive: false),
      '',
    );

    // Eliminar información de remix/versión
    clean = clean.replaceAll(
      RegExp(r'\s*\(.*?(?:Remix|Version|Edit|Mix).*?\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[.*?(?:Remix|Version|Edit|Mix).*?\]', caseSensitive: false),
      '',
    );

    // Eliminar featured artists
    clean = clean.replaceAll(
      RegExp(
        r'\s+(?:ft\.?|feat\.?|featuring|con|with)\s+.*',
        caseSensitive: false,
      ),
      '',
    );

    return clean.trim();
  }

  /// Limpia el nombre del artista para mejor matching
  String _cleanArtist(String artist) {
    String clean = artist;

    // Eliminar " - Topic" de canales auto-generados de YouTube
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false),
      '',
    );

    // Tomar solo el primer artista
    final match = RegExp(r'^([^,&]+)').firstMatch(clean);
    if (match != null) {
      clean = match.group(1) ?? clean;
    }

    return clean.trim();
  }

  /// Calcula similitud entre dos strings usando Levenshtein distance
  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;

    final len1 = s1.length;
    final len2 = s2.length;
    final maxLen = len1 > len2 ? len1 : len2;

    // Levenshtein distance simplificado
    final matrix = List.generate(len1 + 1, (i) => List.filled(len2 + 1, 0));

    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }

    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }

    final distance = matrix[len1][len2];
    return 1.0 - (distance / maxLen);
  }
}
