// lib/services/download_service.dart
import 'dart:io';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../services/saf_helper.dart';
import '../services/innertube_service.dart';
import '../services/ytdlp_service.dart';
import '../services/permission_helper.dart';

class DownloadService {
  final Dio _dio = Dio();

  /// Solicitar permisos de almacenamiento
  Future<bool> requestStoragePermission() async {
    return await PermissionHelper.requestStoragePermission();
  }

  /// Descarga a un archivo temporal y reporta progreso
  Future<String> downloadToTempFile({
    required String url,
    required Function(double) onProgress,
    CancelToken? cancelToken,
    String? customFileName,
  }) async {
    final tempDir = await getTemporaryDirectory();

    // Si se proporciona un nombre personalizado, usarlo
    // De lo contrario, generar uno basado en timestamp
    String fileName;
    if (customFileName != null && customFileName.isNotEmpty) {
      fileName = _sanitizeFileName(customFileName);
    } else {
      // Generar nombre único simple basado en timestamp
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      fileName = 'download_$timestamp.mp3';
    }

    final tempPath = '${tempDir.path}/$fileName';

    try {
      // Soporte para archivos locales pre-descargados
      if (url.startsWith('file://') || File(url).existsSync()) {
        final localFile = File(
          url.startsWith('file://') ? url.replaceFirst('file://', '') : url,
        );
        if (await localFile.exists()) {
          print('[DownloadService] Copiando archivo local: $url');
          await localFile.copy(tempPath);
          onProgress(1.0); // Completado 100%
          return tempPath;
        }
      }

      await _dio.download(
        url,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress(received / total);
          } else {
            onProgress(0);
          }
        },
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: Duration.zero,
          sendTimeout: Duration.zero,
        ),
      );

      // Validar que el archivo se descargó correctamente
      final downloadedFile = File(tempPath);
      if (!await downloadedFile.exists()) {
        throw Exception('El archivo descargado no existe en: $tempPath');
      }

      final fileSize = await downloadedFile.length();
      if (fileSize == 0) {
        await downloadedFile.delete();
        throw Exception('El archivo descargado está vacío (0 bytes)');
      }

      // Validación adicional: archivos MP3 deben tener al menos 1KB
      if (fileSize < 1024) {
        await downloadedFile.delete();
        throw Exception(
          'El archivo descargado es demasiado pequeño ($fileSize bytes), probablemente corrupto',
        );
      }

      print('[DownloadService] Descarga completada: $fileSize bytes');
      return tempPath;
    } catch (e) {
      // Si falla la descarga, intenta borrar el temp file parcial
      try {
        final f = File(tempPath);
        if (await f.exists()) {
          await f.delete();
          print('[DownloadService] Archivo temporal corrupto eliminado');
        }
      } catch (cleanupError) {
        print(
          '[DownloadService] Error al limpiar archivo temporal: $cleanupError',
        );
      }
      rethrow;
    }
  }

  /// Fallback de descarga por YouTube: ahora resuelve con Innertube y
  /// descarga con yt-dlp/ffmpeg embebidos (sin servidores Foranly).
  Future<String?> downloadFromYoutubeFallback({
    required String trackTitle,
    required String artistName,
    required Function(double) onProgress,
  }) async {
    try {
      print(
        '[DownloadService] Fallback YouTube: $trackTitle - $artistName',
      );

      final query = '$trackTitle $artistName'.trim();
      final results = await InnertubeService().searchTracks(
        query,
        limit: 1,
      );
      if (results.isEmpty) return null;

      final result = await YtDlpService().downloadAudio(
        results.first.videoId,
        title: trackTitle,
        artist: artistName,
        onProgress: onProgress,
      );
      return result.filePath;
    } catch (e, st) {
      print('[DownloadService] Error en fallback de YouTube: $e');
      print(st);
      return null;
    }
  }

  /// Descarga y guarda con fallback automático a Foranly
  Future<void> downloadAndSave({
    required String url,
    required String fileName,
    String? treeUri,
    required Function(double) onProgress,
    CancelToken? cancelToken,
    // Nuevos parámetros para fallback
    String? trackTitle,
    String? artistName,
    bool enableYoutubeFallback = true,
    bool forceYouTubeFallback = false, // Ahora fuerza Foranly Search
  }) async {
    String? tempPath;
    final useYoutube = url.trim().isEmpty || forceYouTubeFallback;

    // Detectar si es URL de YouTube
    final isYouTubeUrl =
        url.contains('youtube.com') || url.contains('youtu.be');

    try {
      // 1) URL de YouTube: resolver con yt-dlp/ffmpeg embebidos vía videoId
      if (isYouTubeUrl && !useYoutube) {
        print(
          '[DownloadService] 🎵 YouTube URL detected → yt-dlp embebido',
        );
        print('[DownloadService]    URL: $url');

        final videoId = RegExp(
          r'(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})',
        ).firstMatch(url)?.group(1);
        if (videoId == null) {
          throw Exception('URL de YouTube no reconocida: $url');
        }

        final result = await YtDlpService().downloadAudio(
          videoId,
          title: trackTitle ?? fileName,
          artist: artistName ?? '',
          onProgress: onProgress,
        );
        tempPath = result.filePath;
        print('[DownloadService] Descarga yt-dlp exitosa: $tempPath');
      }
      // 2) Si la URL está vacía o se fuerza YouTube, saltar directo al fallback
      else if (useYoutube) {
        if (forceYouTubeFallback) {
          print('[DownloadService] Forzando búsqueda YouTube (yt-dlp)');
        } else {
          print('[DownloadService] URL vacía, usando fallback YouTube');
        }
        throw Exception('Empty URL or forced YouTube, forcing fallback');
      }
      // 3) Intentar descargar desde la URL original (Spotify Direct/FabDL)
      else {
        print('[DownloadService] Descargando desde API: $url');
        tempPath = await downloadToTempFile(
          url: url,
          onProgress: onProgress,
          cancelToken: cancelToken,
          customFileName: fileName,
        );

        print('[DownloadService] Descarga desde API exitosa');
      }
    } catch (e) {
      print('[DownloadService] Error al descargar desde API: $e');

      // Si fue cancelado por el usuario, NO usar fallback y propagar el error
      if (e is DioException && CancelToken.isCancel(e)) {
        print('Error: Descarga cancelada por el usuario');
        rethrow;
      }

      if (e is DioException && e.type == DioExceptionType.cancel) {
        print('Error: Descarga cancelada por el usuario (DioException)');
        rethrow;
      }

      // 3) Si falla y el fallback está habilitado, intenta YouTube (yt-dlp)
      if (enableYoutubeFallback || forceYouTubeFallback) {
        // Validar que tengamos al menos el título de la canción
        final hasTitle = trackTitle != null && trackTitle.trim().isNotEmpty;
        final hasArtist = artistName != null && artistName.trim().isNotEmpty;

        if (!hasTitle && !hasArtist) {
          throw Exception(
            'No se puede usar el fallback de YouTube: no hay información de track/artist',
          );
        }

        print('[DownloadService] Activando fallback de YouTube...');
        tempPath = await downloadFromYoutubeFallback(
          trackTitle: trackTitle ?? '',
          artistName: artistName ?? '',
          onProgress: onProgress,
        );

        if (tempPath == null) {
          throw Exception(
            'No se pudo descargar ni desde la API ni desde Foranly',
          );
        }
      } else {
        rethrow;
      }
    }

    // 4) Guarda el archivo descargado
    try {
      print('[DownloadService] Guardando archivo: $fileName');

      // Validar tamaño del archivo temporal antes de guardar
      final tempFile = File(tempPath);
      final tempFileSize = await tempFile.length();
      print(
        '[DownloadService] Tamaño del archivo temporal: $tempFileSize bytes',
      );

      if (treeUri != null) {
        final savedUri = await SafHelper.saveFileFromPath(
          treeUri: treeUri,
          tempPath: tempPath,
          fileName: fileName,
        );
        if (savedUri == null) {
          throw Exception(
            'No se pudo guardar el archivo en la carpeta seleccionada',
          );
        }
        print('[DownloadService] Archivo guardado vía SAF en: $savedUri');

        // Validar que el archivo guardado existe y tiene el tamaño correcto
        // Nota: No podemos verificar el tamaño directamente con content:// URIs
        // pero al menos verificamos que SafHelper retornó una URI válida
      } else {
        // Fallback: copiar a Download folder
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
        print('[DownloadService] Archivo guardado en: $destPath');
      }
    } catch (e) {
      print('[DownloadService] Error al guardar archivo: $e');
      rethrow;
    } finally {
      // 5) Limpia archivo temporal
      try {
        final tmp = File(tempPath);
        if (await tmp.exists()) {
          await tmp.delete();
          print('[DownloadService] Archivo temporal eliminado');
        }
      } catch (e) {
        print('[DownloadService] Error al eliminar temporal: $e');
      }
    }
  }

  /// Cancelar descargas
  void cancelDownloads() {
    _dio.close(force: true);
  }

  /// Limpiar recursos
  void dispose() {
    // _foranlyService.dispose(); // Si fuera necesario
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }
}
