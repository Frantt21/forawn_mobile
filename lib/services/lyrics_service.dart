import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:rxdart/rxdart.dart';

import 'lyrics_adjuster.dart';
import 'database_helper.dart';
import '../config/api_config.dart';

class KaraokeWord {
  final Duration timestamp;
  final String text;

  KaraokeWord({required this.timestamp, required this.text});

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.inMilliseconds,
    'text': text,
  };

  factory KaraokeWord.fromJson(Map<String, dynamic> json) => KaraokeWord(
    timestamp: Duration(milliseconds: json['timestamp'] as int),
    text: json['text'] as String,
  );
}

/// Modelo para una línea de lyrics sincronizada
class LyricLine {
  final Duration timestamp;
  final String text;
  final List<KaraokeWord>? words;

  LyricLine({required this.timestamp, required this.text, this.words});

  factory LyricLine.fromString(String line) {
    // Formato: [00:09.23] Texto de la línea
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2})\]\s*(.*)');
    final match = regex.firstMatch(line);

    if (match != null) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final centiseconds = int.parse(match.group(3)!);
      String fullText = match.group(4)!;

      final timestamp = Duration(
        minutes: minutes,
        seconds: seconds,
        milliseconds: centiseconds * (match.group(3)!.length == 3 ? 1 : 10),
      );

      List<KaraokeWord>? words;
      final wordRegex = RegExp(r'(?:<(\d{2}):(\d{2})\.(\d{2,3})>)?([^<]+)');
      if (fullText.contains('<')) {
        words = [];
        final wordMatches = wordRegex.allMatches(fullText);
        for (final wMatch in wordMatches) {
          final wText = wMatch.group(4)!.trimRight();
          if (wText.isEmpty) continue;

          Duration? wTime;
          if (wMatch.group(1) != null) {
            wTime = Duration(
              minutes: int.parse(wMatch.group(1)!),
              seconds: int.parse(wMatch.group(2)!),
              milliseconds:
                  int.parse(wMatch.group(3)!) *
                  (wMatch.group(3)!.length == 3 ? 1 : 10),
            );
          } else {
            wTime = timestamp; // Fallback al timestamp de la línea si no tiene
          }
          words.add(KaraokeWord(timestamp: wTime, text: wText));
        }
      }

      // Limpiar etiquetas de tiempo interno tipo karaoke <00:11.68>
      String cleanText = fullText.replaceAll(
        RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'),
        '',
      );
      // Evitar dobles espacios
      cleanText = cleanText.replaceAll(RegExp(r'\s+'), ' ');

      return LyricLine(
        timestamp: timestamp,
        text: cleanText.trim(),
        words: words,
      );
    }

    // Si no coincide el formato, limpiar posibles etiquetas karaoke igual
    String fallbackText = line.replaceAll(
      RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'),
      '',
    );
    fallbackText = fallbackText.replaceAll(RegExp(r'\s+'), ' ');
    return LyricLine(timestamp: Duration.zero, text: fallbackText.trim());
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.inMilliseconds,
    'text': text,
    'words': words?.map((w) => w.toJson()).toList(),
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    timestamp: Duration(milliseconds: json['timestamp'] as int),
    text: json['text'] as String,
    words: json['words'] != null
        ? (json['words'] as List)
              .map((i) => KaraokeWord.fromJson(Map<String, dynamic>.from(i)))
              .toList()
        : null,
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
  final List<LyricLine>? karaokeLyrics;

  /// Proveedor de las letras ('KPoe' word-by-word o 'LRCLIB' line-by-line).
  final String? source;

  Lyrics({
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
    this.karaokeLyrics,
    this.source,
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
    'karaokeLyrics': karaokeLyrics?.map((l) => l.toJson()).toList(),
    'source': source,
  };

  factory Lyrics.fromJson(Map<String, dynamic> json) => Lyrics(
    trackName: json['trackName'] as String,
    artistName: json['artistName'] as String,
    albumName: json['albumName'] as String?,
    duration: json['duration'] as int?,
    instrumental: json['instrumental'] as bool,
    plainLyrics: json['plainLyrics'] as String? ?? '',
    syncedLyrics:
        (json['syncedLyrics'] as List?)
            ?.map((l) => LyricLine.fromJson(l as Map<String, dynamic>))
            .toList() ??
        [],
    karaokeLyrics: json['karaokeLyrics'] != null
        ? (json['karaokeLyrics'] as List)
              .map((l) => LyricLine.fromJson(l as Map<String, dynamic>))
              .toList()
        : null,
    source: json['source'] as String?,
  );
}

/// Servicio para obtener y cachear lyrics
class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  static const String _cachePrefix = 'lyrics_cache_';
  final Dio _dio = Dio();
  CancelToken? _currentSongCancelToken;

  // Espejos KPoe (LyricsPlus), igual que Scrup: letras word-by-word.
  // Todos se lanzan EN PARALELO; gana el primero (en orden) que responda.
  // Espejos KPoe (LyricsPlus). binimum.org es el espejo estable actualmente
  // (verificado 2026-09); atomix.one es el respaldo oficial y los espejos
  // prjktla siguen por si se recuperan.
  static const List<String> _kpoeServers = [
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.atomix.one',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus.prjktla.my.id',
  ];

  // State Management
  final BehaviorSubject<Lyrics?> _currentLyricsSubject =
      BehaviorSubject<Lyrics?>();
  Stream<Lyrics?> get currentLyricsStream => _currentLyricsSubject.stream;
  Lyrics? get currentLyrics => _currentLyricsSubject.valueOrNull;

  final BehaviorSubject<bool> _isLoadingSubject = BehaviorSubject.seeded(false);
  Stream<bool> get isLoadingStream => _isLoadingSubject.stream;
  bool get isLoading => _isLoadingSubject.value;

  String? _currentTrackingId;

  /// Sets the current song and triggers fetching in background
  Future<void> setCurrentSong(String title, String artist) async {
    final trackingId = '$title-$artist';
    if (_currentTrackingId == trackingId) return; // Already tracking

    // 1. CANCELAR petición anterior para liberar recursos inmediatamente
    if (_currentSongCancelToken != null) {
      _currentSongCancelToken!.cancel('Song changed');
      print('[LyricsService] Cancelled previous fetch due to song change');
    }
    _currentSongCancelToken = CancelToken();

    _currentTrackingId = trackingId;
    _currentLyricsSubject.add(null);
    _isLoadingSubject.add(true); // Start loading

    // Fetch in background con el token de cancelación
    fetchLyrics(title, artist, cancelToken: _currentSongCancelToken)
        .then((lyrics) {
          // Verificar si sigue siendo la canción actual antes de actualizar
          if (_currentTrackingId == trackingId) {
            _currentLyricsSubject.add(lyrics);
            _isLoadingSubject.add(false); // Stop loading
          }
        })
        .catchError((e) {
          // Si fue cancelado, no hacer nada (no actualizar loading a false si ya cambiamos de canción)
          if (e is DioException && CancelToken.isCancel(e)) {
            print('[LyricsService] Fetch cancelled silently');
          } else {
            print('[LyricsService] Error in background fetch: $e');
            if (_currentTrackingId == trackingId) {
              _isLoadingSubject.add(false);
            }
          }
        });
  }

  /// Manually updates the current lyrics (e.g. from manual search selection)
  void updateLyrics(Lyrics lyrics) {
    _currentLyricsSubject.add(lyrics);
    _isLoadingSubject.add(false);
  }

  void clearCurrentLyrics() {
    // Cancelar cualquier carga pendiente
    _currentSongCancelToken?.cancel('Cleared lyrics');
    _currentSongCancelToken = null;

    _currentLyricsSubject.add(null);
    _isLoadingSubject.add(false);
    _currentTrackingId = null;
  }

  /// Called from settings when the sweep preference changes.
  /// If enabled, and current lyrics lacks karaoke data, forces a refetch.
  Future<void> onSweepPreferenceChanged(bool isEnabled) async {
    // Only changes mathematically locally now, no need to refetch
  }

  /// Obtiene lyrics desde la API o caché
  Future<Lyrics?> fetchLyrics(
    String trackName,
    String artistName, {
    int? durationSeconds,
    CancelToken? cancelToken,
  }) async {
    try {
      // Crear clave de caché
      final cacheKey =
          _cachePrefix +
          '${trackName.toLowerCase()}_${artistName.toLowerCase()}'.replaceAll(
            RegExp(r'[^a-z0-9_]'),
            '_',
          );

      // Intentar obtener desde SQLite (Rápido)
      final cachedData = await DatabaseHelper().getLyrics(cacheKey);

      if (cachedData != null) {
        print('[LyricsService] Using cached lyrics for: $trackName');
        final json = jsonDecode(cachedData) as Map<String, dynamic>;
        return Lyrics.fromJson(json);
      }

      // Si no está en caché, obtener desde las APIs
      // Limpiar título y artista antes de buscar
      final cleanTrack = _cleanTitle(trackName);
      final cleanArtist = _cleanArtist(artistName);

      // 1) KPoe (word-by-word), espejos en paralelo — igual que Scrup.
      final kpoe = await _fetchKpoe(
        cleanTrack,
        cleanArtist,
        trackName,
        artistName,
        cancelToken,
      );
      if (kpoe != null) {
        print('[LyricsService] Lyrics (KPoe, word-by-word) found for: $trackName');
        await DatabaseHelper().insertLyrics(
          cacheKey,
          jsonEncode(kpoe.toJson()),
        );
        return kpoe;
      }

      print(
        '[LyricsService] Fetching lyrics from LRCLIB for: $cleanTrack by $cleanArtist',
      );

      // Usar endpoint de búsqueda para mejor matching
      final params = {'q': '$cleanArtist $cleanTrack'};

      // Dio maneja los query params automáticamente
      final response = await _dio.get(
        '${ApiConfig.lyricsBaseUrl}/search',
        queryParameters: params,
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200) {
        final results = response.data as List;

        if (results.isNotEmpty) {
          Map<String, dynamic>? bestMatch;
          double bestScore = -1.0;

          // Buscar el mejor match usando un sistema de puntuación
          for (final item in results) {
            if (cancelToken?.isCancelled ?? false) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.cancel,
              );
            }

            final data = item as Map<String, dynamic>;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            final trackSimilarity = _calculateSimilarity(
              resultTrackName,
              searchTrack,
            );
            final artistSimilarity = _calculateSimilarity(
              resultArtistName,
              searchArtist,
            );

            // Relajamos umbrales: Si la similitud combinada es aceptable o si alguna es perfecta
            if (trackSimilarity < 0.5 || artistSimilarity < 0.5) {
              // Permitimos un escenario donde al menos el título sea idéntico
              if (trackSimilarity < 0.9) continue;
            }

            // Puntaje: Mucho peso a tener synced lyrics
            double currentScore =
                (trackSimilarity * 10) + (artistSimilarity * 10);
            bool hasSynced =
                syncedLyricsRaw != null && syncedLyricsRaw.isNotEmpty;
            if (hasSynced) currentScore += 20;

            if (currentScore > bestScore) {
              bestScore = currentScore;
              bestMatch = data;
            }
          }

          if (bestMatch != null) {
            final data = bestMatch;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final plainLyrics = data['plainLyrics'] as String? ?? '';

            print(
              '[LyricsService] Found best match from LRCLIB (Score: ${bestScore.toStringAsFixed(1)})',
            );

            List<LyricLine> syncedLines = [];
            if (syncedLyricsRaw != null && syncedLyricsRaw.isNotEmpty) {
              syncedLines = syncedLyricsRaw
                  .split('\n')
                  .where((line) => line.trim().isNotEmpty)
                  .map((line) => LyricLine.fromString(line))
                  .where((line) => line.text.isNotEmpty)
                  .toList();
            }

            final lyrics = Lyrics(
              trackName: data['trackName'] as String? ?? trackName,
              artistName: data['artistName'] as String? ?? artistName,
              albumName: data['albumName'] as String?,
              duration: (data['duration'] as num?)?.toInt(),
              instrumental: data['instrumental'] as bool? ?? false,
              plainLyrics: plainLyrics,
              syncedLyrics: syncedLines,
              source: 'LRCLIB',
            );

            await DatabaseHelper().insertLyrics(
              cacheKey,
              jsonEncode(lyrics.toJson()),
            );
            return lyrics;
          }
        }
        print(
          '[LyricsService] No acceptable match found in LRCLIB, trying fallback...',
        );
      } else {
        print(
          '[LyricsService] LRCLIB API error/empty: ${response.statusCode}, trying fallback...',
        );
      }

      // FALLBACK API: api.lyrics.ovh (Solo proporciona lyrics en texto plano)
      try {
        print('[LyricsService] Fetching from lyrics.ovh fallback...');
        final ovhResponse = await _dio.get(
          'https://api.lyrics.ovh/v1/${Uri.encodeComponent(cleanArtist)}/${Uri.encodeComponent(cleanTrack)}',
          cancelToken: cancelToken,
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );

        if (ovhResponse.statusCode == 200 && ovhResponse.data != null) {
          String? lyricsText = ovhResponse.data['lyrics'] as String?;
          if (lyricsText != null && lyricsText.isNotEmpty) {
            // Limpiar metadata promocional que a veces incluye la API
            lyricsText = lyricsText.replaceAll(
              RegExp(r'Paroles de la chanson.*?\n'),
              '',
            );

            print('[LyricsService] Found plain lyrics from lyrics.ovh');
            final lyrics = Lyrics(
              trackName: trackName,
              artistName: artistName,
              instrumental: false,
              plainLyrics: lyricsText.trim(),
              syncedLyrics: [],
              source: 'lyrics.ovh',
            );
            await DatabaseHelper().insertLyrics(
              cacheKey,
              jsonEncode(lyrics.toJson()),
            );
            return lyrics;
          }
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        print('[LyricsService] OVH Fallback API error: $e');
      }

      return null;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        // Relanzar cancelación para que quien llame sepa que fue cancelado
        rethrow;
      }
      print('[LyricsService] Error fetching lyrics: $e');
      return null;
    }
  }

  // ── KPoe (LyricsPlus) — letras word-by-word ─────────────────────────

  Future<Lyrics?> _fetchKpoe(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
    CancelToken? cancelToken,
  ) async {
    final attempts = <Future<Lyrics?>>[
      for (final server in _kpoeServers)
        _tryKpoeServer(
          server,
          cleanTrack,
          cleanArtist,
          originalTitle,
          originalArtist,
          cancelToken,
        ),
    ];
    for (final result in await Future.wait(attempts)) {
      if (result != null) return result;
    }
    return null;
  }

  Future<Lyrics?> _tryKpoeServer(
    String server,
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
    CancelToken? cancelToken,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$server/v2/lyrics/get',
        queryParameters: {'title': cleanTrack, 'artist': cleanArtist},
        cancelToken: cancelToken,
        // 10s: los espejos pueden tardar ~8s en pistas no cacheadas.
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      if (response.statusCode != 200) return null;
      final data = response.data;
      if (data == null) return null;
      final lyricsList = data['lyrics'] as List?;
      if (lyricsList == null || lyricsList.isEmpty) return null;

      final lines = <LyricLine>[];
      final plain = <String>[];
      var hasAnyWords = false;
      for (final item in lyricsList) {
        final ld = item as Map<String, dynamic>;
        final lineTimeMs = (ld['time'] as num?)?.toInt() ?? 0;
        final lineText = ((ld['text'] as String?) ?? '').trim();
        final syllabus = ld['syllabus'] as List?;

        List<KaraokeWord>? words;
        if (syllabus != null && syllabus.isNotEmpty) {
          words = [];
          for (final syl in syllabus) {
            final sd = syl as Map<String, dynamic>;
            final stext = (sd['text'] as String?) ?? '';
            final stimeMs = (sd['time'] as num?)?.toInt() ?? 0;
            if (stext.isNotEmpty) {
              words.add(
                KaraokeWord(
                  timestamp: Duration(milliseconds: stimeMs),
                  text: stext,
                ),
              );
            }
          }
          if (words.isEmpty) words = null;
        }
        if (words != null) hasAnyWords = true;

        if (lineText.isNotEmpty) {
          lines.add(
            LyricLine(
              timestamp: Duration(milliseconds: lineTimeMs),
              text: lineText,
              words: words,
            ),
          );
          plain.add(lineText);
        }
      }
      if (lines.isEmpty) return null;

      final meta = data['metadata'] as Map<String, dynamic>?;
      return Lyrics(
        trackName: (meta?['title'] as String?)?.isNotEmpty == true
            ? meta!['title'] as String
            : originalTitle,
        artistName: (meta?['artist'] as String?)?.isNotEmpty == true
            ? meta!['artist'] as String
            : originalArtist,
        instrumental: false,
        plainLyrics: plain.join('\n'),
        syncedLyrics: lines,
        karaokeLyrics: hasAnyWords ? lines : null,
        source: 'KPoe',
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      return null; // Try next server
    }
  }

  /// Busca lyrics manualmente
  Future<List<Lyrics>> searchLyrics(String query) async {
    final results = <Lyrics>[];
    try {
      final lrclibResults = <Lyrics>[];

      // 1) KPoe (word-by-word): candidatos "Artista - Título" y espejos
      // en paralelo. El LRC reconstruido con tags <mm:ss.xx> se parsea con
      // LyricLine.fromString, que puebla `words` automáticamente.
      for (final cand in _searchCandidates(query)) {
        final attempts = <Future<Lyrics?>>[
          for (final server in _kpoeServers) _kpoeSearchOne(server, cand.$1, cand.$2),
        ];
        for (final res in await Future.wait(attempts)) {
          if (res != null) {
            results.add(res);
            break;
          }
        }
        if (results.isNotEmpty) break;
      }

      // 2) LRCLIB (line-by-line), respaldo de KPoe.
      final response = await _dio.get(
        '${ApiConfig.lyricsBaseUrl}/search',
        queryParameters: {'q': query},
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200) {
        final List items = response.data;
        lrclibResults.addAll(
          items.map<Lyrics>((item) {
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
            source: 'LRCLIB',
          );
        }),
        );
        results.addAll(lrclibResults);
      }
      return results;
    } catch (e) {
      print('[LyricsService] Error searching lyrics: $e');
      return results;
    }
  }

  /// Consulta un espejo de KPoe para la búsqueda manual; null si no
  /// responde o no trae letras. Reconstruye LRC con tags <mm:ss.xx> por
  /// sílaba para preservar el modo word-by-word al aplicar el resultado.
  Future<Lyrics?> _kpoeSearchOne(
    String server,
    String title,
    String artist,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$server/v2/lyrics/get',
        queryParameters: {'title': title, 'artist': artist},
        // 10s: los espejos pueden tardar ~8s en pistas no cacheadas.
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      if (response.statusCode != 200) return null;
      final data = response.data;
      if (data == null) return null;
      final lyricsList = data['lyrics'] as List?;
      if (lyricsList == null || lyricsList.isEmpty) return null;
      final meta = data['metadata'] as Map<String, dynamic>?;

      final lrcLines = <String>[];
      final plainLines = <String>[];
      for (final item in lyricsList) {
        final ld = item as Map<String, dynamic>;
        final t = (ld['time'] as num?)?.toInt() ?? 0;
        final text = ((ld['text'] as String?) ?? '').trim();
        final syllabus = ld['syllabus'] as List?;
        var line = '[${_lrcTs(t)}]';
        var hasWords = false;
        if (syllabus != null && syllabus.isNotEmpty) {
          final words = <String>[];
          for (final syl in syllabus) {
            final sd = syl as Map<String, dynamic>;
            final st = (sd['time'] as num?)?.toInt() ?? 0;
            final stext = (sd['text'] as String?) ?? '';
            if (stext.isEmpty) continue;
            words.add('<${_lrcTs(st)}>$stext');
          }
          if (words.isNotEmpty) {
            line += ' ${words.join(' ')}';
            hasWords = true;
          }
        }
        if (!hasWords) line += ' $text';
        lrcLines.add(line);
        plainLines.add(text);
      }

      final syncedLines = lrcLines
          .map((line) => LyricLine.fromString(line))
          .where((line) => line.text.isNotEmpty)
          .toList();
      if (syncedLines.isEmpty) return null;

      return Lyrics(
        trackName: (meta?['title'] as String?)?.isNotEmpty == true
            ? meta!['title'] as String
            : title,
        artistName: (meta?['artist'] as String?)?.isNotEmpty == true
            ? meta!['artist'] as String
            : artist,
        instrumental: false,
        plainLyrics: plainLines.join('\n'),
        syncedLyrics: syncedLines,
        karaokeLyrics: syncedLines.any((l) => l.words != null) ? syncedLines : null,
        source: 'KPoe',
      );
    } catch (_) {
      return null;
    }
  }

  /// Genera candidatos (título, artista) para KPoe a partir de la query
  /// libre ("Artista - Título", "Título by Artista", o texto tal cual).
  static List<(String, String)> _searchCandidates(String query) {
    final candidates = <(String, String)>[];
    void add(String t, String a) {
      t = t.trim();
      a = a.trim();
      if (t.isEmpty || a.isEmpty) return;
      final pair = (t.toLowerCase(), a.toLowerCase());
      for (final c in candidates) {
        if (c.$1 == pair.$1 && c.$2 == pair.$2) return;
      }
      candidates.add((t, a));
    }

    final q = query.trim();
    final dashParts = q.split(RegExp(r'\s+[-–—]\s+'));
    if (dashParts.length == 2) {
      add(dashParts[0], dashParts[1]);
      add(dashParts[1], dashParts[0]);
    }
    final byMatch = RegExp(
      r'^(.*?)\s+by\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(q);
    if (byMatch != null) {
      add(byMatch.group(1)!, byMatch.group(2)!);
    }
    return candidates;
  }

  static String _lrcTs(int ms) {
    final mins = ms ~/ 60000;
    final secs = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10;
    return '${mins.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
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

      await DatabaseHelper().insertLyrics(
        cacheKey,
        jsonEncode(lyrics.toJson()),
      );
      print('[LyricsService] Manual lyrics saved for $localTrackName (SQLite)');
    } catch (e) {
      print('[LyricsService] Error saving manual lyrics: $e');
    }
  }

  /// Limpia el caché de lyrics
  Future<void> clearCache() async {
    try {
      await DatabaseHelper().clearAllLyrics();
      print('[LyricsService] Lyrics cache cleared (SQLite)');
    } catch (e) {
      print('[LyricsService] Error clearing cache: $e');
    }
  }

  /// Obtiene el tamaño del caché
  Future<int> getCacheSize() async {
    try {
      return await DatabaseHelper().countLyrics();
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
