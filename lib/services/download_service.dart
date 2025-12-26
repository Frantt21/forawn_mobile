// lib/services/download_service.dart
import 'dart:io';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../services/saf_helper.dart';
import '../services/foranly_service.dart';
import '../services/permission_helper.dart';

class DownloadService {
  final Dio _dio = Dio();
  final ForanlyService _foranlyService = ForanlyService();

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
      return tempPath;
    } catch (e) {
      // Si falla la descarga, intenta borrar el temp file parcial
      try {
        final f = File(tempPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Descarga desde Foranly como fallback
  /// Retorna la ruta del archivo temporal
  Future<String?> downloadFromYoutubeFallback({
    required String trackTitle,
    required String artistName,
    required Function(double) onProgress,
  }) async {
    try {
      print(
        '[DownloadService] Iniciando búsqueda en Foranly: $trackTitle - $artistName',
      );

      final query = '$trackTitle - $artistName';
      final downloadUrl = await _foranlyService.getDownloadUrlWait(query);

      if (downloadUrl != null) {
        print('[DownloadService] URL obtenida de Foranly: $downloadUrl');
        return await downloadToTempFile(
          url: downloadUrl,
          onProgress: onProgress,
          customFileName: '$trackTitle - $artistName.mp3',
        );
      } else {
        print('[DownloadService] Foranly no pudo encontrar/generar la URL');
        return null;
      }
    } catch (e, st) {
      print('[DownloadService] Error en fallback de Foranly: $e');
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

    try {
      // 1) Si la URL está vacía o se fuerza YouTube, saltar directo a Foranly Search
      if (useYoutube) {
        if (forceYouTubeFallback) {
          print('[DownloadService] Forzando Foranly Search (App Logic)');
        } else {
          print('[DownloadService] URL vacía, usando Foranly directamente');
        }
        throw Exception('Empty URL or forced YouTube, forcing fallback');
      }

      // 2) Intentar descargar desde la URL original (Spotify Direct/FabDL)
      print('[DownloadService] Descargando desde API: $url');
      tempPath = await downloadToTempFile(
        url: url,
        onProgress: onProgress,
        cancelToken: cancelToken,
        customFileName: fileName,
      );

      print('[DownloadService] Descarga desde API exitosa');
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

      // 3) Si falla y el fallback está habilitado, intenta Foranly
      if (enableYoutubeFallback || forceYouTubeFallback) {
        // Validar que tengamos al menos el título de la canción
        final hasTitle = trackTitle != null && trackTitle.trim().isNotEmpty;
        final hasArtist = artistName != null && artistName.trim().isNotEmpty;

        if (!hasTitle && !hasArtist) {
          throw Exception(
            'No se puede usar Foranly fallback: no hay información de track/artist',
          );
        }

        print('[DownloadService] Activando fallback de Foranly...');
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
        print('[DownloadService] Archivo guardado vía SAF');
      } else {
        // Fallback: copiar a Download folder
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          try {
            await downloadsDir.create(recursive: true);
          } catch (_) {}
        }
        final destPath = '${downloadsDir.path}/$fileName';
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
