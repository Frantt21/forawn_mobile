import 'dart:async';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:dio/dio.dart';
import '../models/download_history_item.dart';
import '../models/spotify_track.dart';
import 'download_service.dart';
import 'spotify_service.dart';
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

  // Map para trackear los CancelTokens activos y poder cancelarlos
  final Map<String, CancelToken> _activeCancelTokens = {};

  final SpotifyService _spotifyService = SpotifyService();
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

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
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

      String? downloadUrl;

      // ⚡ DETECTAR SI ES URL DE GOOGLE DRIVE (CACHÉ)
      final isGoogleDriveUrl = track.url.contains('drive.google.com');

      // ⚡ DETECTAR SI ES URL DE YOUTUBE
      final isYouTubeUrl =
          track.url.contains('youtube.com') || track.url.contains('youtu.be');

      if (isGoogleDriveUrl) {
        // Usar URL de Google Drive directamente (desde caché)
        print('[GlobalDownloadManager] ⚡ Using cached Google Drive URL');
        downloadUrl = track.url;
      } else if (isYouTubeUrl) {
        // ⚡ SI ES URL DE YOUTUBE, PASAR URL DIRECTA A FORANLY
        print(
          '[GlobalDownloadManager] ⚡ YouTube URL detected → Sending directly to Foranly',
        );
        print('[GlobalDownloadManager]    URL: ${track.url}');
        downloadUrl = track.url; // ✅ Pasar URL de YouTube directamente
      } else if (forceYouTubeFallback) {
        // ⚡ SI SE FUERZA FORANLY (Youtube Fallback), SALTAR SPOTIFY SERVICE
        print(
          '[GlobalDownloadManager] ⚡ Forzando modo búsqueda Foranly (Skip Spotify APIs)',
        );
        downloadUrl = ""; // Dejar vacío para que DownloadService use fallback
      } else {
        // Intentar obtener URL de descarga desde Spotify Direct (FabDL)
        // SOLO si la URL es de Spotify
        try {
          final downloadInfo = await _spotifyService.getDownloadUrl(
            track.url,
            trackName: trackName,
            artistName: artistName,
          );

          // ⚠️ VERIFICAR CANCELACIÓN INMEDIATAMENTE DESPUÉS DE OBTENER URL
          if (_activeDownloads[downloadId]?.isCancelled == true) {
            print(
              '[GlobalDownloadManager] Descarga cancelada después de obtener URL: $downloadId',
            );
            _activeDownloads.remove(downloadId);
            _notificationsPlugin.cancel(downloadId.hashCode);
            return;
          }

          if (downloadInfo.downloadUrl.isNotEmpty) {
            downloadUrl = downloadInfo.downloadUrl;
            if (downloadInfo.name.isNotEmpty) trackName = downloadInfo.name;
            if (downloadInfo.artists.isNotEmpty) {
              artistName = downloadInfo.artists;
            }
          }
        } catch (e) {
          print('[GlobalDownloadManager] API failed: $e');

          // Verificar si fue cancelada durante el error
          if (_activeDownloads[downloadId]?.isCancelled == true) {
            print(
              '[GlobalDownloadManager] Descarga cancelada durante error de API: $downloadId',
            );
            _activeDownloads.remove(downloadId);
            _notificationsPlugin.cancel(downloadId.hashCode);
            return;
          }
        }
      }

      // Crear nombre de archivo
      final fileName = artistName.isNotEmpty
          ? '$trackName - $artistName.mp3'
          : '$trackName.mp3';
      final cleanFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      // Verificar si fue cancelada antes de iniciar la descarga
      if (_activeDownloads[downloadId]?.isCancelled == true) {
        print(
          '[GlobalDownloadManager] Descarga cancelada antes de iniciar: $downloadId',
        );
        _activeCancelTokens.remove(downloadId);
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        return;
      }

      // Crear CancelToken para esta descarga
      final cancelToken = CancelToken();
      _activeCancelTokens[downloadId] = cancelToken;

      // Descargar archivo
      await _downloadService.downloadAndSave(
        url: downloadUrl ?? '',
        fileName: cleanFileName,
        treeUri: treeUri,
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
        cancelToken: cancelToken,
        trackTitle: trackName,
        artistName: artistName,
        enableYoutubeFallback:
            !forceYouTubeFallback, // Deshabilitar API si se fuerza YouTube
        forceYouTubeFallback: forceYouTubeFallback, // Nuevo parámetro
      );

      // Limpiar el CancelToken después de completar
      _activeCancelTokens.remove(downloadId);

      // Verificar una última vez si fue cancelada (por si acaso)
      if (_activeDownloads[downloadId]?.isCancelled == true) {
        print(
          '[GlobalDownloadManager] Descarga completada pero estaba cancelada, limpiando: $downloadId',
        );
        _activeCancelTokens.remove(downloadId);
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

        // Guardar en historial
        final historyItem = DownloadHistoryItem(
          id: downloadId,
          name: trackName,
          artists: artistName,
          imageUrl: pinterestImageUrl,
          downloadUrl: downloadUrl ?? '',
          downloadedAt: DateTime.now(),
          source: downloadUrl != null ? 'spotify' : 'youtube',
          durationMs: null,
        );
        await DownloadHistoryService.addToHistory(historyItem);

        // Cancelar notificación de progreso existente para evitar conflictos
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

        // Remover de activas después de 3 segundos
        Future.delayed(const Duration(seconds: 3), () {
          _activeDownloads.remove(downloadId);
          _notifyListeners();
        });
      }
    } catch (e) {
      // Ignorar si es error de cancelación (ya se manejó o no es error real)
      if (e is DioException && CancelToken.isCancel(e)) {
        print(
          '[GlobalDownloadManager] Cancelación capturada en catch: $downloadId',
        );
        _activeCancelTokens.remove(downloadId);
        _activeDownloads.remove(downloadId);
        _notifyListeners();
        _notificationsPlugin.cancel(downloadId.hashCode);
        return;
      }

      print('[GlobalDownloadManager] Download error: $e');

      // Limpiar el CancelToken en caso de error
      _activeCancelTokens.remove(downloadId);

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

      // Cancelar el CancelToken para detener la descarga en curso
      if (_activeCancelTokens.containsKey(downloadId)) {
        try {
          _activeCancelTokens[downloadId]?.cancel(
            'Descarga cancelada por el usuario',
          );
          _activeCancelTokens.remove(downloadId);
          print(
            '[GlobalDownloadManager] CancelToken cancelado para $downloadId',
          );
        } catch (e) {
          print('[GlobalDownloadManager] Error cancelando CancelToken: $e');
        }
      }

      // NO remover de _activeDownloads aquí - dejar que downloadTrack() lo detecte y limpie
      // _activeDownloads.remove(downloadId); ← REMOVIDO

      // Cancelar notificación
      _notificationsPlugin.cancel(downloadId.hashCode);

      print(
        '[GlobalDownloadManager] Descarga marcada como cancelada: $downloadId',
      );
    }
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
