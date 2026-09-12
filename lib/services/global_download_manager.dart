import 'dart:async';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/download_history_item.dart';
import '../models/spotify_track.dart';
import 'download_service.dart';
import 'ytdlp_service.dart';
import 'innertube_service.dart';
import 'saf_helper.dart';
import 'download_history_service.dart';
import 'notification_history_service.dart';
import 'lyrics_service.dart';

/// Estado de una descarga dentro de la lista de activas.
enum DownloadPhase { queued, downloading, completed, failed }

/// Modelo para una descarga en progreso
class ActiveDownload {
  final String id;
  final SpotifyTrack track;
  final String? pinterestImageUrl;

  /// Para descargas de VIDEO: format_id elegido en el diálogo de
  /// resoluciones. null = descarga de AUDIO (mp3).
  final String? videoFormatId;

  /// Fase actual: en cola → descargando → completada/fallida.
  final DownloadPhase phase;
  double progress;
  bool isCompleted;
  bool isCancelled;
  String? error;

  ActiveDownload({
    required this.id,
    required this.track,
    this.pinterestImageUrl,
    this.videoFormatId,
    this.phase = DownloadPhase.downloading,
    this.progress = 0.0,
    this.isCompleted = false,
    this.isCancelled = false,
    this.error,
  });

  /// true si el job es de vídeo (mp4), false si es de audio (mp3).
  bool get isVideo => videoFormatId != null;

  ActiveDownload copyWith({DownloadPhase? phase, double? progress}) {
    return ActiveDownload(
      id: id,
      track: track,
      pinterestImageUrl: pinterestImageUrl,
      videoFormatId: videoFormatId,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      isCompleted: isCompleted,
      isCancelled: isCancelled,
      error: error,
    );
  }
}

/// Servicio global de descargas con notificaciones
class GlobalDownloadManager {
  static final GlobalDownloadManager _instance =
      GlobalDownloadManager._internal();
  factory GlobalDownloadManager() => _instance;
  GlobalDownloadManager._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final Map<String, ActiveDownload> _activeDownloads = {};
  final StreamController<Map<String, ActiveDownload>> _downloadsController =
      StreamController<Map<String, ActiveDownload>>.broadcast();

  /// Parámetros de descargas en cola para arrancarlas vía [_processQueue].
  final Map<String, ({String? treeUri, bool forceYouTubeFallback, String? videoFormatId})>
  _queuedParams = {};

  // Map para trackear las descargas canceladas por el usuario.
  final Set<String> _cancelledDownloads = {};

  final DownloadService _downloadService = DownloadService();

  bool _isInitialized = false;

  /// Stream de descargas activas (cualquier fase).
  Stream<Map<String, ActiveDownload>> get downloadsStream =>
      _downloadsController.stream;

  /// Descargas en estado "en cola" (esperando que termine la actual).
  List<ActiveDownload> get queuedDownloads => _activeDownloads.values
      .where((d) => d.phase == DownloadPhase.queued)
      .toList();

  /// Descargas en estado "en curso".
  List<ActiveDownload> get downloadingDownloads => _activeDownloads.values
      .where((d) => d.phase == DownloadPhase.downloading)
      .toList();

  /// Obtener descargas activas
  Map<String, ActiveDownload> get activeDownloads =>
      Map.unmodifiable(_activeDownloads);

  /// Inicializar el servicio de notificaciones
  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings('ic_stat_logo');
    const initSettings = InitializationSettings(android: androidSettings);

    await _notificationsPlugin.initialize(initSettings);
    _isInitialized = true;

    print('[GlobalDownloadManager] Initialized');
  }

  /// Solicitar permisos de notificaciones (Android 13+)
  Future<bool> requestNotificationPermissions() async {
    if (Platform.isAndroid) {
      final androidPlugin = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        return granted ?? false;
      }
    }
    return true;
  }

  /// Verificar si las notificaciones están habilitadas en configuración
  Future<bool> _areNotificationsEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('notifications_enabled') ?? false;
    } catch (e) {
      print(
        '[GlobalDownloadManager] Error checking notification preference: $e',
      );
      return false; // Por defecto desactivadas si hay error
    }
  }

  /// Agregar una descarga a la cola
  ///
  /// [startNow]: false encola la descarga sin ejecutarla (fase "en cola");
  /// la lista se procesa FIFO: al no quedar nada en curso, arranca la
  /// primera en cola. true (default) la descarga inmediatamente.
  Future<String> addDownload({
    required SpotifyTrack track,
    String? pinterestImageUrl,
    String? treeUri,
    bool forceYouTubeFallback = false,
    bool startNow = true,

    /// Para VIDEO: format_id del diálogo de resoluciones. null = audio.
    String? videoFormatId,
  }) async {
    // Lazy init
    if (!_isInitialized) await initialize();

    final downloadId = const Uuid().v4();

    final hasActiveJob = _activeDownloads.values.any(
      (d) => d.phase == DownloadPhase.downloading,
    );
    // Auto-cola: si ya hay una descarga en curso, la nueva entra "en cola"
    // aunque el caller pida startNow, para no saturar el dispositivo con
    // varios yt-dlp+ffmpeg en paralelo.
    final effectiveStart = startNow && !hasActiveJob;

    final activeDownload = ActiveDownload(
      id: downloadId,
      track: track,
      pinterestImageUrl: pinterestImageUrl,
      videoFormatId: videoFormatId,
      phase: effectiveStart
          ? DownloadPhase.downloading
          : DownloadPhase.queued,
    );

    _activeDownloads[downloadId] = activeDownload;
    print(
      '[GlobalDownloadManager] ✅ Download added to active list: $downloadId - ${track.title}',
    );
    print(
      '[GlobalDownloadManager] 📊 Active downloads count: ${_activeDownloads.length}',
    );
    _notifyListeners();

    // Iniciar descarga en segundo plano (solo si no quedó en cola)
    if (effectiveStart) {
      _startDownload(
        downloadId,
        track,
        pinterestImageUrl,
        treeUri,
        forceYouTubeFallback,
        videoFormatId: videoFormatId,
      );
    } else {
      _queuedParams[downloadId] = (
        treeUri: treeUri,
        forceYouTubeFallback: forceYouTubeFallback,
        videoFormatId: videoFormatId,
      );
    }

    return downloadId;
  }

  /// Procesa la cola FIFO: arranca la primera descarga "en cola" si no hay
  /// ninguna en curso. Se llama al completar (o fallar) cada descarga.
  void _processQueue() {
    final hasActiveJob = _activeDownloads.values.any(
      (d) => d.phase == DownloadPhase.downloading,
    );
    if (hasActiveJob) return;

    final next = _activeDownloads.values
        .where((d) => d.phase == DownloadPhase.queued && !d.isCancelled)
        .toList();
    if (next.isEmpty) return;

    // Orden de llegada: insertar preserva el orden en el Map literal de
    // inserción de Dart; usamos el id como desempate estable.
    next.sort((a, b) => a.id.compareTo(b.id));
    final job = next.first;

    _activeDownloads[job.id] = job.copyWith(phase: DownloadPhase.downloading);
    _notifyListeners();

    // Reanudar con los parámetros guardados.
    final params = _queuedParams.remove(job.id);
    if (params == null) {
      _activeDownloads.remove(job.id);
      _notifyListeners();
      _processQueue();
      return;
    }
    _startDownload(
      job.id,
      job.track,
      job.pinterestImageUrl,
      params.treeUri,
      params.forceYouTubeFallback,
      videoFormatId: params.videoFormatId,
    );
  }

  /// Iniciar descarga (audio mp3 o video mp4 según [videoFormatId]).
  Future<void> _startDownload(
    String downloadId,
    SpotifyTrack track,
    String? pinterestImageUrl,
    String? treeUri,
    bool forceYouTubeFallback, {
    String? videoFormatId,
  }) async {
    final download = _activeDownloads[downloadId];
    if (download == null || download.isCancelled) return;

    try {
      // Mostrar notificación inicial
      await _showDownloadNotification(
        downloadId,
        track.title,
        'Iniciando descarga...',
        0,
      );

      // Extraer información del track
      String trackName = track.title.trim();
      String artistName = track.artists.trim();

      if (artistName.isEmpty && trackName.contains(' - ')) {
        final parts = trackName.split(' - ');
        if (parts.length >= 2) {
          artistName = parts[0].trim();
          trackName = parts.sublist(1).join(' - ').trim();
        }
      }

      // Resolver el videoId de YouTube: o viene en track.url como watch?v=,
      // o se busca con Innertube por título+artista (metadata exacta).
      String? videoId;
      final ytIdRe = RegExp(
        r'(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})',
      );
      final idMatch = ytIdRe.firstMatch(track.url);
      if (idMatch != null) {
        videoId = idMatch.group(1);
      } else {
        final query = '$trackName $artistName'.trim();
        final results = await InnertubeService().searchTracks(
          query,
          limit: 1,
        );
        if (results.isNotEmpty) videoId = results.first.videoId;
      }

      if (videoId == null) {
        throw Exception(
          'No se pudo resolver la pista de YouTube para "$trackName"',
        );
      }

      // Verificar si fue cancelada antes de iniciar la descarga
      if (_cancelledDownloads.contains(downloadId)) {
        print(
          '[GlobalDownloadManager] Descarga cancelada antes de iniciar: $downloadId',
        );
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        _processQueue();
        return;
      }

      // Crear nombre de archivo
      String cleanFileName;
      if (videoFormatId != null) {
        // VIDEO: la extensión real se conoce DESPUÉS de descargar (yt-dlp
        // decide el contenedor según el formato elegido: webm, mp4, mkv...).
        // Se ajusta más abajo, tras la descarga, antes de guardar.
        cleanFileName = '';
      } else {
        final fileName = artistName.isNotEmpty
            ? '$trackName - $artistName.mp3'
            : '$trackName.mp3';
        cleanFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      }

      // Verificar si fue cancelada antes de iniciar la descarga
      if (_cancelledDownloads.contains(downloadId)) {
        print(
          '[GlobalDownloadManager] Descarga cancelada antes de iniciar: $downloadId',
        );
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        _processQueue();
        return;
      }

      // Descargar con yt-dlp+ffmpeg EMBEBIDOS (sin servidores externos).
      // AUDIO: los metadatos (título, artista, portada) salen de Innertube y
      // se incrustan con ffmpeg durante la extracción.
      // VIDEO: lógica del video_downloader de Forawn desktop (format_id del
      // diálogo de resoluciones + mux mp4).
      final YtDlpDownloadResult result;
      if (videoFormatId != null) {
        result = await YtDlpService().downloadVideo(
          track.url,
          formatId: videoFormatId,
          title: trackName,
          onProgress: (progress) {
            if (_activeDownloads.containsKey(downloadId)) {
              _activeDownloads[downloadId]!.progress = progress;
              _notifyListeners();
              if (progress < 0.99) {
                _showDownloadNotification(
                  downloadId,
                  track.title,
                  'Descargando...',
                  (progress * 100).toInt(),
                );
              }
            }
          },
        );
      } else {
        result = await YtDlpService().downloadAudio(
          videoId,
          title: trackName,
          artist: artistName,
          onProgress: (progress) {
            if (_activeDownloads.containsKey(downloadId)) {
              _activeDownloads[downloadId]!.progress = progress;
              _notifyListeners();

              // Actualizar notificación con progreso
              // Evitar actualizar al 100% aquí para no dejar la notificación "pegada" como ongoing
              if (progress < 0.99) {
                _showDownloadNotification(
                  downloadId,
                  track.title,
                  'Descargando...',
                  (progress * 100).toInt(),
                );
              }
            }
          },
        );
      }

      // Mover el mp3/mp4/webm temporal a su destino final (SAF o Download/).
      if (videoFormatId != null) {
        // VIDEO: extensión real del archivo descargado (no la supuesta).
        final ext = result.filePath.contains('.')
            ? result.filePath.substring(result.filePath.lastIndexOf('.') + 1)
                  .toLowerCase()
            : 'mp4';
        final vName = '$trackName.$ext';
        cleanFileName = vName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      }
      await _saveToDestination(
        result.filePath,
        cleanFileName,
        treeUri,
      );

      // Verificar una última vez si fue cancelada (por si acaso)
      if (_activeDownloads[downloadId]?.isCancelled == true) {
        print(
          '[GlobalDownloadManager] Descarga completada pero estaba cancelada, limpiando: $downloadId',
        );
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        return;
      }

      // Descargar lyrics en segundo plano (no bloquear)
      _downloadLyricsInBackground(trackName, artistName);

      // Marcar como completada
      if (_activeDownloads.containsKey(downloadId)) {
        _activeDownloads[downloadId]!
          ..isCompleted = true
          ..progress = 1.0
          ..error = null;
        _activeDownloads[downloadId] = _activeDownloads[downloadId]!
            .copyWith(phase: DownloadPhase.completed);
        _notifyListeners();

        // Lanzar la siguiente descarga en cola de inmediato (el item
        // completado permanece 3s en la lista para feedback visual).
        _processQueue();

        // 🛡️ Safe Block: Ejecutar acciones post-descarga con manejo de errores independiente
        // para asegurar que si falla una notificación o historial, NO se marque la descarga como fallida
        try {
          // Guardar en historial
          final historyItem = DownloadHistoryItem(
            id: downloadId,
            name: trackName,
            artists: artistName,
            imageUrl: pinterestImageUrl,
            downloadUrl: track.url,
            downloadedAt: DateTime.now(),
            source: videoFormatId != null ? 'video' : 'youtube',
            durationMs: null,
          );
          await DownloadHistoryService.addToHistory(historyItem);
        } catch (e) {
          print('[GlobalDownloadManager] Error guardando historial: $e');
        }

        try {
          // Cancelar notificación de progreso
          await _notificationsPlugin.cancel(downloadId.hashCode);

          // Mostrar notificación de completado
          await _showCompletedNotification(downloadId, track.title);

          // Guardar en historial de notificaciones
          await NotificationHistoryService.addNotification(
            DownloadNotification(
              id: downloadId,
              title: 'Descarga completada',
              message: track.title,
              timestamp: DateTime.now(),
              type: NotificationType.success,
              imageUrl: pinterestImageUrl,
            ),
          );
        } catch (e) {
          print('[GlobalDownloadManager] Error en notificaciones finales: $e');
        }

        // Remover de activas después de 3 segundos
        Future.delayed(const Duration(seconds: 3), () {
          _activeDownloads.remove(downloadId);
          _notifyListeners();
        });
      }
    } catch (e) {
      // Ignorar si la descarga fue cancelada por el usuario.
      if (_cancelledDownloads.contains(downloadId)) {
        print(
          '[GlobalDownloadManager] Cancelación capturada en catch: $downloadId',
        );
        _cancelledDownloads.remove(downloadId);
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        _notificationsPlugin.cancel(downloadId.hashCode);
        _processQueue();
        return;
      }

      print('[GlobalDownloadManager] Download error: $e');

      // Limpiar el estado de cancelación en caso de error
      _cancelledDownloads.remove(downloadId);

      if (_activeDownloads.containsKey(downloadId)) {
        _activeDownloads[downloadId]!
          ..error = e.toString();
        _activeDownloads[downloadId] = _activeDownloads[downloadId]!
            .copyWith(phase: DownloadPhase.failed);
        _notifyListeners();

        // Continuar con la cola aunque esta descarga haya fallado.
        _processQueue();

        // Mostrar notificación de error
        await _showErrorNotification(downloadId, track.title, e.toString());

        // Guardar en historial de notificaciones
        await NotificationHistoryService.addNotification(
          DownloadNotification(
            id: downloadId,
            title: 'Error en descarga',
            message: track.title,
            timestamp: DateTime.now(),
            type: NotificationType.error,
            imageUrl: pinterestImageUrl,
          ),
        );

        // Remover de activas después de 5 segundos
        Future.delayed(const Duration(seconds: 5), () {
          _activeDownloads.remove(downloadId);
          _notifyListeners();
        });
      }
    }
  }

  /// Cancelar descarga
  void cancelDownload(String downloadId) {
    if (_activeDownloads.containsKey(downloadId)) {
      _activeDownloads[downloadId]!.isCancelled = true;
      _notifyListeners();

      // Marcar como cancelada y abortar yt-dlp si está corriendo.
      _cancelledDownloads.add(downloadId);
      YtDlpService().cancel();

      // Cancelar notificación
      _notificationsPlugin.cancel(downloadId.hashCode);

      // Si estaba en cola (sin proceso activo), sacarla directamente.
      final d = _activeDownloads[downloadId];
      if (d != null && d.phase == DownloadPhase.queued) {
        _activeDownloads.remove(downloadId);
        _queuedParams.remove(downloadId);
        _notifyListeners();
      }

      print(
        '[GlobalDownloadManager] Descarga marcada como cancelada: $downloadId',
      );
    }
  }

  /// Mueve el mp3 descargado a su destino final: SAF treeUri si existe,
  /// o la carpeta pública Download/ como fallback.
  Future<void> _saveToDestination(
    String tempPath,
    String fileName,
    String? treeUri,
  ) async {
    if (treeUri != null) {
      final savedUri = await SafHelper.saveFileFromPath(
        treeUri: treeUri,
        tempPath: tempPath,
        fileName: fileName,
      );
      if (savedUri == null) {
        throw Exception('No se pudo guardar el archivo en la carpeta seleccionada');
      }
      print('[GlobalDownloadManager] Archivo guardado vía SAF en: $savedUri');
    } else {
      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (!await downloadsDir.exists()) {
        try {
          await downloadsDir.create(recursive: true);
        } catch (_) {}
      }

      String destPath = '${downloadsDir.path}/$fileName';

      // Manejar colisiones de nombre: agregar (1), (2), etc.
      if (await File(destPath).exists()) {
        int counter = 1;
        String nameWithoutExt = fileName;
        String ext = '';
        if (fileName.contains('.')) {
          nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.'));
          ext = fileName.substring(fileName.lastIndexOf('.'));
        }
        while (await File(destPath).exists()) {
          destPath = '${downloadsDir.path}/$nameWithoutExt ($counter)$ext';
          counter++;
        }
      }

      await File(tempPath).copy(destPath);
      print('[GlobalDownloadManager] Archivo guardado en: $destPath');
    }

    // Limpia el archivo temporal
    try {
      final tmp = File(tempPath);
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  /// Mostrar notificación de descarga en progreso
  Future<void> _showDownloadNotification(
    String downloadId,
    String title,
    String message,
    int progress,
  ) async {
    // Verificar si las notificaciones están habilitadas
    if (!await _areNotificationsEnabled()) return;

    final androidDetails = AndroidNotificationDetails(
      'downloads',
      'Descargas',
      channelDescription: 'Notificaciones de descargas de música',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      ongoing: true,
      autoCancel: false,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      downloadId.hashCode,
      title,
      message,
      notificationDetails,
    );
  }

  /// Mostrar notificación de descarga completada
  Future<void> _showCompletedNotification(
    String downloadId,
    String title,
  ) async {
    // Verificar si las notificaciones están habilitadas
    if (!await _areNotificationsEnabled()) return;

    final androidDetails = AndroidNotificationDetails(
      'downloads_completed',
      'Descargas Completadas',
      channelDescription: 'Notificaciones de descargas completadas',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      downloadId.hashCode,
      'Descarga completada',
      title,
      notificationDetails,
    );
  }

  /// Mostrar notificación de error
  Future<void> _showErrorNotification(
    String downloadId,
    String title,
    String error,
  ) async {
    // Verificar si las notificaciones están habilitadas
    if (!await _areNotificationsEnabled()) return;

    final androidDetails = AndroidNotificationDetails(
      'downloads_error',
      'Errores de Descarga',
      channelDescription: 'Notificaciones de errores en descargas',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      downloadId.hashCode,
      'Error en descarga',
      title,
      notificationDetails,
    );
  }

  /// Notificar a los listeners
  void _notifyListeners() {
    if (!_downloadsController.isClosed) {
      _downloadsController.add(Map.from(_activeDownloads));
    }
  }

  /// Descargar lyrics en segundo plano sin bloquear
  void _downloadLyricsInBackground(String trackName, String artistName) {
    if (trackName.isEmpty) return;

    // Ejecutar en segundo plano sin esperar
    Future.microtask(() async {
      try {
        print(
          '[GlobalDownloadManager] Downloading lyrics for: $trackName - $artistName',
        );
        final lyrics = await LyricsService().fetchLyrics(trackName, artistName);
        if (lyrics != null) {
          print(
            '[GlobalDownloadManager] Lyrics downloaded successfully: ${lyrics.lineCount} lines',
          );
        } else {
          print(
            '[GlobalDownloadManager] No lyrics found for: $trackName - $artistName',
          );
        }
      } catch (e) {
        print('[GlobalDownloadManager] Error downloading lyrics: $e');
      }
    });
  }

  /// Limpiar recursos
  void dispose() {
    _downloadsController.close();
  }
}
