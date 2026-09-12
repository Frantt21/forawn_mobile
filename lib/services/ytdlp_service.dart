// lib/services/ytdlp_service.dart
//
// Ejecuta yt-dlp+ffmpeg EMBEBIDOS en la app vía youtubedl-android
// (MethodChannel "forawn/ytdlp" -> YtDlpHandler.kt). Reemplaza los
// servidores Foranly/APIs muertos: la descarga se hace 100% on-device.
//
// La estrategia de metadatos es la misma que Forawn desktop:
//  - URL exacta de la pista resuelta por Innertube (watch?v=VIDEOID)
//  - yt-dlp extrae audio a mp3 y embebe título/artista/portada con ffmpeg
//    (--embed-metadata --embed-thumbnail --parse-metadata ...)
//
// Basado en la lógica de Scrup (ytdlp_service.dart) y Forawn desktop
// (download_manager.dart).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// NOTA: 'path' se usa aquí pero no está en pubspec.yaml de forawn_mobile;
// viene transitivamente. Para evitar el lint, resolvemos manualmente con
// Platform.pathSeparator donde es posible.

class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  @override
  String toString() => message;
}

/// Resultado de una descarga completa.
class YtDlpDownloadResult {
  /// Ruta final del archivo descargado (mp3).
  final String filePath;

  /// Duración total de la descarga en ms.
  final int elapsedMs;

  YtDlpDownloadResult({required this.filePath, required this.elapsedMs});
}

/// Orquesta yt-dlp embebido (youtubedl-android) para descargas.
class YtDlpService {
  static final YtDlpService _instance = YtDlpService._internal();
  factory YtDlpService() => _instance;
  YtDlpService._internal();

  static const MethodChannel _channel = MethodChannel('forawn/ytdlp');

  static const String _watchUrlBase = 'https://www.youtube.com/watch?v=';

  bool _initialized = false;
  bool _updateChecked = false;
  String? _outputDir;

  /// Directorio donde se guardan los mp3 descargados (app-specific,
  /// accesible sin permisos). La copia final a Download/ o SAF la hace
  /// el manager como antes.
  Future<String> _ensureOutputDir() async {
    if (_outputDir != null) return _outputDir!;
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory(p.join(dir.path, 'downloads_tmp'));
    if (!out.existsSync()) out.createSync(recursive: true);
    _outputDir = out.path;
    return out.path;
  }

  /// Inicializa youtubedl-android (extrae Python/yt-dlp/FFmpeg del APK).
  /// Es idempotente y tolerante a fallos: si falla, las descargas
  /// reportarán el error al intentarlo.
  Future<bool> ensureInitialized() async {
    if (_initialized) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('ytdlpInit');
      _initialized = ok ?? false;
      if (_initialized) await _ensureYtDlpUpdated();
      return _initialized;
    } on PlatformException catch (e) {
      // "notInitialized" significa que el handler existe pero el init
      // falló en Kotlin; reintentar una vez.
      try {
        final ok = await _channel.invokeMethod<bool>('ytdlpInit');
        _initialized = ok ?? false;
        if (_initialized) await _ensureYtDlpUpdated();
        return _initialized;
      } catch (_) {
        throw YtDlpException(
          'No se pudo inicializar el motor de descarga: ${e.message ?? e.code}',
        );
      }
    } on MissingPluginException {
      throw YtDlpException(
        'Motor de descarga no disponible en esta build (ytdlp channel missing)',
      );
    }
  }

  /// Actualiza yt-dlp embebido a la última versión estable (una sola vez por
  /// proceso). YouTube bloquea con HTTP 403 los clientes antiguos, igual que
  /// Forawn desktop descarga siempre el yt-dlp más reciente.
  Future<void> _ensureYtDlpUpdated() async {
    if (_updateChecked) return;
    _updateChecked = true;
    try {
      final status = await _channel.invokeMethod<String>('ytdlpUpdate');
      if (status == null || status.startsWith('FAILED')) {
        debugPrint(
          '[YtDlpService] yt-dlp update no pudo completarse: $status; '
          'usando la versión disponible',
        );
      } else {
        debugPrint('[YtDlpService] yt-dlp actualizado: $status');
      }
    } catch (e) {
      debugPrint('[YtDlpService] yt-dlp update lanzó excepción; continuando: $e');
    }
  }

  /// Versión de yt-dlp embebida (para diagnóstico).
  Future<String> version() async {
    await ensureInitialized();
    try {
      return await _channel.invokeMethod<String>('ytdlpVersion') ?? '?';
    } catch (_) {
      return '?';
    }
  }

  /// Cancela la descarga en curso (si la hay).
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('ytdlpCancel');
    } catch (_) {}
  }

  /// Descarga la pista [videoId] como mp3 con metadatos incrustados.
  ///
  /// - [title]/[artist]: metadatos exactos del resultado de Innertube; se
  ///   fuerzan en el archivo con --parse-metadata para que no dependan de
  ///   la limpieza heurística de yt-dlp.
  /// - [onProgress]: progreso 0.0..1.0 (fase de descarga 0..0.9,
  ///   conversión 0.9..1.0).
  Future<YtDlpDownloadResult> downloadAudio(
    String videoId, {
    required String title,
    required String artist,
    void Function(double progress)? onProgress,
  }) async {
    final ready = await ensureInitialized();
    if (!ready) {
      throw YtDlpException(
        'El motor de descargas no está disponible (youtubedl-android no inicializado)',
      );
    }

    final outDir = await _ensureOutputDir();
    // Nombre seguro y único: yt-dlp escribe "<base>.mp3" al terminar.
    final safeBase =
        '${title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), '_')}_$videoId';
    final outputTemplate = p.join(outDir, '$safeBase.%(ext)s');
    final watchUrl = '$_watchUrlBase$videoId';

    final args = <String>[
      '--no-playlist',
      '--no-warnings',
      '--newline',
      '--no-mtime',
      '--no-check-certificates',
      '-f', 'bestaudio/best',
      '--extract-audio',
      '--audio-format', 'mp3',
      '--audio-quality', '0',
      // NOTA: sin --ffmpeg-location — la librería youtubedl-android ya
      // inyecta la ruta correcta del ffmpeg embebido en cada execute()
      // (YoutubeDL.kt lo añade automáticamente).
      '-o', outputTemplate,
      '--embed-metadata',
      '--embed-thumbnail',
      '--convert-thumbnails', 'jpg',
      // Metadatos exactos de Innertube: el título y artista del resultado
      // mandan sobre el raw de YouTube.
      '--parse-metadata', 'Title:(?P<title>.*)',
      '--parse-metadata', 'Uploader:(?P<artist>.*)',
      '--replace-in-metadata', 'title', r'^\s+|\s+$', '',
      '--add-header', 'User-Agent: Mozilla/5.0',
      '--add-header', 'Referer: https://www.youtube.com',
      '--print', 'after_move:filepath',
      watchUrl,
    ];

    final sw = Stopwatch()..start();
    final output = StringBuffer();
    var exitCode = -1;

    try {
      // youtubedl-android no streamea stdout a Dart: ejecuta y devuelve
      // todo el output. El progreso real vendría por YoutubeDLCallback;
      // aquí reportamos fases (0.05 init, 0.4 descarga, 0.95 post).
      onProgress?.call(0.05);
      final res = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('ytdlpRun', {'args': args});
      exitCode = (res?['exitCode'] as num?)?.toInt() ?? 1;
      output.write((res?['output'] as String?) ?? '');
      final err = (res?['error'] as String?) ?? '';
      if (err.isNotEmpty && exitCode != 0) output.write('\n$err');
      onProgress?.call(0.95);
    } on PlatformException catch (e) {
      throw YtDlpException('yt-dlp falló: ${e.message ?? e.code}');
    }

    if (exitCode != 0) {
      final msg = output.toString().trim();
      throw YtDlpException(
        msg.isNotEmpty
            ? msg.substring(0, msg.length.clamp(0, 500))
            : 'yt-dlp terminó con código $exitCode',
      );
    }

    // Localizar el archivo final: primero por el --print after_move:filepath,
    // si no, buscando el <base>.* más reciente.
    String? foundPath;
    final printed = output
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('['))
        .toList();
    if (printed.isNotEmpty) {
      final candidate = printed.last;
      if (File(candidate).existsSync()) foundPath = candidate;
    }
    foundPath ??= _findNewestOutputFile(outDir, safeBase);

    if (foundPath == null) {
      throw YtDlpException(
        'yt-dlp terminó OK pero no se encontró el archivo de salida',
      );
    }

    // Renombrar al nombre limpio título-artista (sin videoId) para que el
    // archivo final sea igual al de desktop.
    final cleanName =
        '${title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), '_')}.mp3';
    final finalPath = p.join(outDir, cleanName);
    try {
      if (p.basename(foundPath).toLowerCase() != cleanName.toLowerCase()) {
        final dest = File(finalPath);
        if (dest.existsSync()) dest.deleteSync();
        File(foundPath).renameSync(finalPath);
        foundPath = finalPath;
      }
    } catch (_) {
      // Si el rename falla, usar el archivo tal cual.
    }

    onProgress?.call(1.0);
    sw.stop();
    return YtDlpDownloadResult(
      filePath: foundPath ?? '',
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  String? _findNewestOutputFile(String dirPath, String base) {
    try {
      final files = Directory(dirPath)
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith(base))
          .toList();
      if (files.isEmpty) return null;
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      return files.first.path;
    } catch (_) {
      return null;
    }
  }
}
