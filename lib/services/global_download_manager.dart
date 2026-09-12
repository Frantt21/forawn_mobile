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

/// Modelo para una descarga en progreso
class ActiveDownload {
  final String id;
  final SpotifyTrack track;
  final String? pinterestImageUrl;
  double progress;
  bool isCompleted;
  bool isCancelled;
  String? error;

  ActiveDownload({
    required this.id,
    required this.track,
    this.pinterestImageUrl,
    this.progress = 0.0,
    this.isCompleted = false,
    this.isCancelled = false,
    this.error,
  });
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

  // Map para trackear las descargas canceladas por el usuario.
  final Set<String> _cancelledDownloads = {};

  final DownloadService _downloadService = DownloadService();

  bool _isInitialized = false;

  /// Stream de descargas activas
  Stream<Map<String, ActiveDownload>> get downloadsStream =>
      _downloadsController.stream;

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
  Future<String> addDownload({
    required SpotifyTrack track,
    String? pinterestImageUrl,
    String? treeUri,
    bool forceYouTubeFallback = false,
  }) async {
    // Lazy init
    if (!_isInitialized) await initialize();

    final downloadId = const Uuid().v4();

    final activeDownload = ActiveDownload(
      id: downloadId,
      track: track,
      pinterestImageUrl: pinterestImageUrl,
    );

    _activeDownloads[downloadId] = activeDownload;
    print(
      '[GlobalDownloadManager] ✅ Download added to active list: $downloadId - ${track.title}',
    );
    print(
      '[GlobalDownloadManager] 📊 Active downloads count: ${_activeDownloads.length}',
    );
    _notifyListeners();

    // Iniciar descarga en segundo plano
    _startDownload(
      downloadId,
      track,
      pinterestImageUrl,
      treeUri,
      forceYouTubeFallback,
    );

    return downloadId;
  }

  /// Iniciar descarga
  Future<void> _startDownload(
    String downloadId,
    SpotifyTrack track,
    String? pinterestImageUrl,
    String? treeUri,
    bool forceYouTubeFallback,
  ) async {
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
        return;
      }

      // Crear nombre de archivo
      final fileName = artistName.isNotEmpty
          ? '$trackName - $artistName.mp3'
          : '$trackName.mp3';
      final cleanFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      // Verificar si fue cancelada antes de iniciar la descarga
      if (_cancelledDownloads.contains(downloadId)) {
        print(
          '[GlobalDownloadManager] Descarga cancelada antes de iniciar: $downloadId',
        );
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        return;
      }

      // Descargar con yt-dlp+ffmpeg EMBEBIDOS (sin servidores externos).
      // Los metadatos (título, artista, portada) salen de Innertube y se
      // incrustan con ffmpeg durante la extracción.
      final result = await YtDlpService().downloadAudio(
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

      // Mover el mp3 temporal a su destino final (SAF o Download/).
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
        _activeDownloads[downloadId]!.isCompleted = true;
        _activeDownloads[downloadId]!.progress = 1.0;
        _notifyListeners();

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
            source: 'youtube',
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
        return;
      }

      print('[GlobalDownloadManager] Download error: $e');

      // Limpiar el estado de cancelación en caso de error
      _cancelledDownloads.remove(downloadId);

      if (_activeDownloads.containsKey(downloadId)) {
        _activeDownloads[downloadId]!.error = e.toString();
        _notifyListeners();

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
