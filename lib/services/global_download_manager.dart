import 'dart:async';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/download_history_item.dart';
import '../models/spotify_track.dart';
import 'download_service.dart';
import 'spotify_service.dart';
import 'download_history_service.dart';
import 'notification_history_service.dart';

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
  }) async {
    final downloadId = const Uuid().v4();

    final activeDownload = ActiveDownload(
      id: downloadId,
      track: track,
      pinterestImageUrl: pinterestImageUrl,
    );

    _activeDownloads[downloadId] = activeDownload;
    _notifyListeners();

    // Iniciar descarga en segundo plano
    _startDownload(downloadId, track, pinterestImageUrl, treeUri);

    return downloadId;
  }

  /// Iniciar descarga
  Future<void> _startDownload(
    String downloadId,
    SpotifyTrack track,
    String? pinterestImageUrl,
    String? treeUri,
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

      // Intentar obtener URL de descarga
      try {
        final downloadInfo = await _spotifyService.getDownloadUrl(
          track.url,
          trackName: trackName,
          artistName: artistName,
        );

        if (downloadInfo.downloadUrl.isNotEmpty) {
          downloadUrl = downloadInfo.downloadUrl;
          if (downloadInfo.name.isNotEmpty) trackName = downloadInfo.name;
          if (downloadInfo.artists.isNotEmpty)
            artistName = downloadInfo.artists;
        }
      } catch (e) {
        print('[GlobalDownloadManager] API failed: $e');
      }

      // Crear nombre de archivo
      final fileName = artistName.isNotEmpty
          ? '$trackName - $artistName.mp3'
          : '$trackName.mp3';
      final cleanFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

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
            _showDownloadNotification(
              downloadId,
              track.title,
              'Descargando...',
              (progress * 100).toInt(),
            );
          }
        },
        cancelToken: null,
        trackTitle: trackName,
        artistName: artistName,
        enableYoutubeFallback: true,
      );

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
          ),
        );

        // Remover de activas después de 3 segundos
        Future.delayed(const Duration(seconds: 3), () {
          _activeDownloads.remove(downloadId);
          _notifyListeners();
        });
      }
    } catch (e) {
      print('[GlobalDownloadManager] Download error: $e');

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
      _activeDownloads.remove(downloadId);
      _notifyListeners();

      // Cancelar notificación
      _notificationsPlugin.cancel(downloadId.hashCode);
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

  /// Limpiar recursos
  void dispose() {
    _downloadsController.close();
  }
}
