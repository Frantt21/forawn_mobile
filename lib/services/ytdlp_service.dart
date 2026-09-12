// lib/services/ytdlp_service.dart
//
// Ejecuta yt-dlp+ffmpeg EMBEBIDOS en la app vía youtubedl-android
// (MethodChannel "forawn/ytdlp" -> YtDlpHandler.kt). Reemplaza los
// servidores Foranly/APIs muertos: la descarga se hace 100% on-device.
//
// Estrategia heredada de Forawn desktop:
//  - AUDIO: URL exacta de la pista resuelta por Innertube (watch?v=VIDEOID),
//    yt-dlp extrae audio a mp3 y embebe título/artista/portada con ffmpeg
//    (--embed-metadata --embed-thumbnail --parse-metadata ...).
//  - VIDEO: metadatos vía yt-dlp -j (mismo _ytdlpMetadata del desktop) y
//    descarga por format_id elegido por el usuario, con mux a mp4 cuando el
//    formato es vídeo-only (compatibilidad con el player del sistema).

import 'dart:async';
import 'dart:convert' show JsonDecoder;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  @override
  String toString() => message;
}

/// Resultado de una descarga completa.
class YtDlpDownloadResult {
  /// Ruta final del archivo descargado (mp3 o mp4).
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

  /// Progreso en tiempo real de yt-dlp emitido por YtDlpHandler.kt durante
  /// la ejecución (0.0..1.0). Sin listener no emite nada.
  static const EventChannel _progressChannel =
      EventChannel('forawn/ytdlp/progress');

  static const String _watchUrlBase = 'https://www.youtube.com/watch?v=';

  bool _initialized = false;
  bool _updateChecked = false;
  String? _outputDir;

  /// Cache de metadatos por URL (evita un segundo -j entre el sondeo de
  /// formatos y la descarga, mismo efecto que en desktop).
  final Map<String, Map<String, dynamic>> _videoMetaCache = {};

  /// Directorio donde se guardan los archivos descargados (app-specific,
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

  // ---------------------------------------------------------------------------
  // Progreso con easing compartido (audio y video)
  // ---------------------------------------------------------------------------

  /// Progreso suavizado: yt-dlp emite pocos eventos reales (solo líneas
  /// "[download] NN.N%") y para archivos pequeños saltan casi directo a 100%.
  /// Este easing hace que la barra avance de forma estable hacia el destino
  /// real y no salte de 5% a completo: un timer acerca `displayed` a `target`
  /// en pasos pequeños, y `displayed` llega a 1.0 recién al completar.
  _EasedProgress _startEasedProgress(void Function(double)? onProgress) =>
      _EasedProgress(onProgress);

  /// Ejecuta yt-dlp con progreso en vivo y devuelve el output combinado.
  /// Lanza [YtDlpException] si el proceso termina con código != 0.
  Future<String> _runYtDlp(
    List<String> args, {
    void Function(double progress)? onProgress,
  }) async {
    final ease = _startEasedProgress(onProgress);
    final output = StringBuffer();

    // Escucha el progreso real emitido por YtDlpHandler en el canal
    // "forawn/ytdlp/progress" mientras se ejecuta la descarga.
    final progressSub = _progressChannel.receiveBroadcastStream().listen(
      (e) {
        final p = (e as Map?)?['progress'];
        if (p is num) ease.followNative(p.toDouble());
      },
      onError: (_) {},
    );

    try {
      // youtubedl-android no streamea stdout a Dart: ejecuta y devuelve
      // todo el output; el progreso llega por el EventChannel de arriba.
      ease.snap(0.05);
      final res = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('ytdlpRun', {'args': args});
      final exitCode = (res?['exitCode'] as num?)?.toInt() ?? 1;
      output.write((res?['output'] as String?) ?? '');
      final err = (res?['error'] as String?) ?? '';
      if (err.isNotEmpty) output.write('\n$err');
      // Post-proceso (conversión/mux/renombrado) = última etapa hacia 1.0.
      ease.snap(0.98);

      if (exitCode != 0) {
        final msg = output.toString().trim();
        throw YtDlpException(
          msg.isNotEmpty
              ? msg.substring(0, msg.length.clamp(0, 500))
              : 'yt-dlp terminó con código $exitCode',
        );
      }
      return output.toString();
    } on PlatformException catch (e) {
      throw YtDlpException('yt-dlp falló: ${e.message ?? e.code}');
    } finally {
      await progressSub.cancel();
      ease.dispose();
    }
  }

  /// Localiza el archivo final: primero por el --print after_move:filepath,
  /// si no, buscando el <base>.* más reciente en [outDir].
  String? _locateOutput(String output, String outDir, String safeBase) {
    final printed = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('['))
        .toList();
    if (printed.isNotEmpty) {
      final candidate = printed.last;
      if (File(candidate).existsSync()) return candidate;
    }
    return _findNewestOutputFile(outDir, safeBase);
  }

  /// Sanitiza un título para usarlo como nombre de archivo.
  static String _safeName(String title) =>
      title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), '_');

  // ---------------------------------------------------------------------------
  // Metadatos de vídeo (equivalente a _ytdlpMetadata del desktop)
  // ---------------------------------------------------------------------------

  /// Metadatos crudos de un vídeo vía `yt-dlp -j` (una sola pasada, se
  /// parsea el primer objeto JSON válido del output). Cachea por URL para
  /// no re-sondear entre el diálogo de resoluciones y la descarga.
  Future<Map<String, dynamic>?> fetchVideoMetadata(String url) async {
    final ready = await ensureInitialized();
    if (!ready) {
      throw YtDlpException(
        'El motor de descargas no está disponible (youtubedl-android no inicializado)',
      );
    }

    final cached = _videoMetaCache[url];
    if (cached != null) return cached;

    final output = await _runYtDlp([
      '--no-playlist',
      '--no-warnings',
      '--no-check-certificates',
      '-j',
      '--ignore-errors',
      url,
    ]);

    if (output.trim().isEmpty) return null;

    for (final line in output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || !t.startsWith('{')) continue;
      try {
        final decoded = jsonDecodeCompat(t);
        if (decoded != null) {
          _videoMetaCache[url] = decoded;
          return decoded;
        }
      } catch (_) {
        // Línea no-JSON; probar la siguiente.
      }
    }
    return null;
  }

  /// jsonDecode sin importar dart:convert en el API pública del servicio.
  Map<String, dynamic>? jsonDecodeCompat(String line) {
    try {
      final v = const JsonDecoder().convert(line);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Descargas
  // ---------------------------------------------------------------------------

  /// Descarga la pista [videoId] como mp3 con metadatos incrustados.
  ///
  /// - [title]/[artist]: metadatos exactos del resultado de Innertube; se
  ///   fuerzan en el archivo con --parse-metadata/--replace-in-metadata
  ///   para que no dependan de la limpieza heurística de yt-dlp.
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

    final cleanTitle = title.trim();
    // Canal "X - Topic" → "X" (defensivo; Innertube ya lo trae limpio).
    final cleanArtist = artist
        .trim()
        .replaceAll(RegExp(r'\s*-\s*Topic\s*$'), '')
        .trim();

    final outDir = await _ensureOutputDir();
    // Nombre seguro y único: yt-dlp escribe "<base>.mp3" al terminar.
    final safeBase = '${_safeName(title)}_$videoId';
    final outputTemplate = p.join(outDir, '$safeBase.%(ext)s');
    final watchUrl = '$_watchUrlBase$videoId';
    final sw = Stopwatch()..start();

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
      //
      // IMPORTANTE: no usar prefijos 'Uploader:'/'Title:' — el campo
      // 'uploader' es None en el info dict moderno de YouTube, por lo que
      // yt-dlp SALTABA el parse y el archivo quedaba SIN artista (los
      // templates de campos faltantes se renderizan como "NA"). Patrón
      // probado (igual que desktop y Scrup/ytdlnis):
      //  1. Crear 'artist' desde 'channel' (siempre presente en YouTube).
      //  2. Sobrescribir title/artist con los valores EXACTOS de Innertube
      //     vía --replace-in-metadata (solo escapa '\\'; '$' es literal en
      //     los reemplazos de Python re).
      '--parse-metadata', 'channel:(?P<artist>.*)',
      '--replace-in-metadata', 'title', r'^.*$',
      _literalReplacement(cleanTitle),
      if (cleanArtist.isNotEmpty) ...[
        '--replace-in-metadata', 'artist', r'^.*$',
        _literalReplacement(cleanArtist),
      ],
      '--replace-in-metadata', 'title', r'^\s+|\s+$', '',
      '--replace-in-metadata', 'artist', r'^\s+|\s+$', '',
      '--add-header', 'User-Agent: Mozilla/5.0',
      '--add-header', 'Referer: https://www.youtube.com',
      '--print', 'after_move:filepath',
      watchUrl,
    ];

    final output = await _runYtDlp(args, onProgress: onProgress);
    var foundPath = _locateOutput(output, outDir, safeBase);

    if (foundPath == null) {
      throw YtDlpException(
        'yt-dlp terminó OK pero no se encontró el archivo de salida',
      );
    }

    // Renombrar al nombre limpio título-artista (sin videoId) para que el
    // archivo final sea igual al de desktop.
    final cleanName = cleanArtist.isNotEmpty
        ? '${_safeName('$cleanTitle - $cleanArtist')}.mp3'
        : '${_safeName(cleanTitle)}.mp3';
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
      filePath: foundPath!,
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  /// Escapa un valor para usarlo como REEMPLAZO literal de
  /// --replace-in-metadata (yt-dlp aplica Python re.sub: solo '\\' es
  /// especial en el reemplazo; '$' es literal y NO debe escaparse).
  static String _literalReplacement(String value) =>
      value.replaceAll(r'\', r'\\');

  /// Descarga un vídeo de YouTube con la lógica del video_downloader de
  /// Forawn desktop, adaptada a Android:
  ///  - [formatId]: formato elegido por el usuario (del sondeo con
  ///    [fetchVideoMetadata]).
  ///  - Si el formato es vídeo-only, se muxa con el mejor audio a mp4
  ///    (ffmpeg embebido); si es progresivo/muxed, se baja tal cual.
  ///  - Archivo final "<Título>.mp4" (o la extensión real del contenedor).
  Future<YtDlpDownloadResult> downloadVideo(
    String url, {
    required String formatId,
    required String title,
    void Function(double progress)? onProgress,
  }) async {
    final ready = await ensureInitialized();
    if (!ready) {
      throw YtDlpException(
        'El motor de descargas no está disponible (youtubedl-android no inicializado)',
      );
    }

    final outDir = await _ensureOutputDir();
    final safeBase = '${_safeName(title)}_$formatId';
    final outputTemplate = p.join(outDir, '$safeBase.%(ext)s');
    final sw = Stopwatch()..start();

    final args = <String>[
      '--no-playlist',
      '--no-warnings',
      '--newline',
      '--no-mtime',
      '--no-check-certificates',
      // Formato elegido; si es vídeo-only mux con el mejor audio (igual que
      // el DownloadManager de desktop hace con el format_id del usuario).
      '-f', '$formatId+bestaudio/$formatId/best',
      '--merge-output-format', 'mp4',
      '-o', outputTemplate,
      '--embed-metadata',
      '--add-header', 'User-Agent: Mozilla/5.0',
      '--add-header', 'Referer: https://www.youtube.com',
      '--print', 'after_move:filepath',
      url,
    ];

    final output = await _runYtDlp(args, onProgress: onProgress);
    var foundPath = _locateOutput(output, outDir, safeBase);

    if (foundPath == null) {
      throw YtDlpException(
        'yt-dlp terminó OK pero no se encontró el archivo de salida',
      );
    }

    // Renombrar a "<Título>.<ext real>" (sin format_id). Se respeta la
    // extensión del contenedor real para no romper la reproducción.
    final dot = foundPath.lastIndexOf('.');
    final ext = dot >= 0 ? foundPath.substring(dot).toLowerCase() : '.mp4';
    final cleanName = '${_safeName(title)}$ext';
    try {
      if (p.basename(foundPath).toLowerCase() != cleanName.toLowerCase()) {
        final dest = File(p.join(outDir, cleanName));
        if (dest.existsSync()) dest.deleteSync();
        File(foundPath).renameSync(dest.path);
        foundPath = dest.path;
      }
    } catch (_) {
      // Si el rename falla, usar el archivo tal cual.
    }

    onProgress?.call(1.0);
    sw.stop();
    return YtDlpDownloadResult(
      filePath: foundPath!,
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

/// Progreso suavizado compartido entre descargas de audio y vídeo.
class _EasedProgress {
  static const double capAtRun = 0.9; // tope durante la ejecución de yt-dlp
  final void Function(double)? onProgress;
  double shown = 0.0; // último valor entregado a onProgress (monótono)
  double displayed = 0.0; // valor actual de la barra (easing)
  double target = capAtRun; // valor real hacia el que nos acercamos
  Timer? _ticker;

  _EasedProgress(this.onProgress) {
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (displayed >= target) return;
      final step = (target - displayed) * 0.18;
      displayed = (displayed + step).clamp(0.0, 1.0);
      if (displayed > shown) {
        shown = displayed;
        onProgress?.call(displayed);
      }
    });
  }

  /// Salto inmediato (fases sintéticas: 0.05 al iniciar, ~1.0 al finalizar).
  void snap(double p) {
    final v = p.clamp(0.0, 1.0);
    if (v <= shown) return;
    target = v;
    displayed = v;
    shown = v;
    onProgress?.call(v);
  }

  /// El progreso real (EventChannel) solo sube `target`; la barra se acerca
  /// de forma suave vía ticker. Nunca baja, y se topa en capAtRun hasta que
  /// la fase completa haga snap a 1.0.
  void followNative(double p) {
    final v = p.clamp(0.0, capAtRun);
    if (v > target) target = v;
  }

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
  }
}
