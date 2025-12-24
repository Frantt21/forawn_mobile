// lib/services/lyrics_adjuster.dart
import 'lyrics_service.dart';

/// Servicio para ajustar timestamps de lyrics cuando hay desincronización
class LyricsAdjuster {
  /// Ajusta los lyrics basándose en la duración esperada vs real
  static Lyrics adjustLyrics({
    required Lyrics lyrics,
    required Duration expectedDuration,
    required Duration actualDuration,
  }) {
    // Si no hay lyrics sincronizados, retornar sin cambios
    if (lyrics.syncedLyrics.isEmpty) {
      return lyrics;
    }

    // Calcular diferencia en segundos
    final difference = (actualDuration.inSeconds - expectedDuration.inSeconds)
        .abs();

    // Si la diferencia es muy pequeña (<1 segundo), no ajustar
    if (difference < 1) {
      print(
        '[LyricsAdjuster] Difference too small ($difference s), no adjustment needed',
      );
      return lyrics;
    }

    print('[LyricsAdjuster] Adjusting lyrics:');
    print('  Expected duration: ${expectedDuration.inSeconds}s');
    print('  Actual duration: ${actualDuration.inSeconds}s');
    print('  Difference: $difference s');

    // Detectar si hay intro extra
    final introOffset = _detectIntro(lyrics.syncedLyrics);
    print('  Detected intro offset: ${introOffset.inSeconds}s');

    // Calcular ratio de ajuste
    final ratio =
        actualDuration.inMilliseconds / expectedDuration.inMilliseconds;
    print('  Adjustment ratio: ${ratio.toStringAsFixed(3)}');

    // Ajustar cada línea
    final adjustedLines = lyrics.syncedLyrics.map((line) {
      // Aplicar ajuste proporcional (sin offset de intro por ahora)
      // El offset de intro causa más problemas que soluciones en la mayoría de casos
      final adjustedMillis = (line.timestamp.inMilliseconds * ratio).round();

      return LyricLine(
        timestamp: Duration(milliseconds: adjustedMillis),
        text: line.text,
      );
    }).toList();

    print('[LyricsAdjuster] ✓ Adjusted ${adjustedLines.length} lines');

    // Retornar lyrics ajustados
    return Lyrics(
      trackName: lyrics.trackName,
      artistName: lyrics.artistName,
      albumName: lyrics.albumName,
      duration: actualDuration.inSeconds,
      instrumental: lyrics.instrumental,
      plainLyrics: lyrics.plainLyrics,
      syncedLyrics: adjustedLines,
    );
  }

  /// Detecta si hay una intro extra comparando el timestamp de la primera línea
  static Duration _detectIntro(List<LyricLine> syncedLyrics) {
    if (syncedLyrics.isEmpty) return Duration.zero;

    // Si la primera línea está después de 5 segundos, probablemente hay intro
    final firstLineTime = syncedLyrics.first.timestamp;

    // Buscar la primera línea con texto real (no vacía)
    final firstRealLine = syncedLyrics.firstWhere(
      (line) => line.text.trim().isNotEmpty,
      orElse: () => syncedLyrics.first,
    );

    // Si la primera línea real está después de 5 segundos, hay intro
    if (firstRealLine.timestamp.inSeconds > 5) {
      return Duration(seconds: firstRealLine.timestamp.inSeconds - 2);
    }

    return Duration.zero;
  }

  /// Ajusta un timestamp individual (útil para ajustes manuales)
  static Duration adjustTimestamp({
    required Duration originalTimestamp,
    required Duration expectedDuration,
    required Duration actualDuration,
    Duration introOffset = Duration.zero,
  }) {
    if (expectedDuration.inMilliseconds == 0) return originalTimestamp;

    final ratio =
        actualDuration.inMilliseconds / expectedDuration.inMilliseconds;
    final adjustedMillis =
        ((originalTimestamp.inMilliseconds + introOffset.inMilliseconds) *
                ratio)
            .round();

    return Duration(milliseconds: adjustedMillis);
  }
}
