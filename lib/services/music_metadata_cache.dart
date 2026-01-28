// lib/services/music_metadata_cache.dart
import 'dart:io';
import 'dart:typed_data';
// import 'package:image/image.dart' as img; // Ya no usamos compresión pesada
import 'package:path_provider/path_provider.dart';
import 'database_helper.dart';

/// Metadata de una canción (clase pública para uso externo)
class SongMetadata {
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artworkPath; // Ruta al archivo (cacheado)
  final String? artworkUri; // URI content:// de Android
  final int? dominantColor; // Color dominante cacheado

  SongMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.artworkPath,
    this.artworkUri,
    this.dominantColor,
  });
}

/// Servicio de caché persistente para metadata de música (FileSystem + SQLite)
///
/// Características optimizadas:
/// - Almacenamiento metadata en SQLite (Rápido y eficiente)
/// - Artworks solo se guardan en disco, no en RAM
/// - Limpieza automática de caché antiguo (>30 días)
class MusicMetadataCache {
  // Caché en memoria para acceso rápido durante la sesión (Solo Texto/Rutas)
  static final Map<String, _CachedMetadata> _memoryCache = {};

  // Configuración
  static const int maxCacheAge = 30; // días

  /// Obtener archivo de caché para una key
  static Future<File> _getCacheFile(String key) async {
    final dir = await getApplicationCacheDirectory();
    final safeKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final fileName = 'art_$safeKey.jpg';
    return File('${dir.path}/$fileName');
  }

  /// Obtener metadata del caché (memoria O disco/sqlite)
  static Future<SongMetadata?> get(String key) async {
    // 1. Memoria
    if (_memoryCache.containsKey(key)) {
      return _convertToSongMetadata(_memoryCache[key]!);
    }

    try {
      // 2. Base de Datos (SQLite)
      final dbHelper = DatabaseHelper();
      final data = await dbHelper.getMetadata(key);

      if (data == null) return null;

      // Intentar leer imagen del sistema de archivos usando la ruta almacenada
      // Si la ruta no existe en DB, intentamos la ruta generada por defecto
      String? artworkPath = data['artwork_path'] as String?;

      // Fallback backward database compatibility
      if (artworkPath == null || artworkPath.isEmpty) {
        final defaultFile = await _getCacheFile(key);
        if (await defaultFile.exists()) {
          artworkPath = defaultFile.path;
        }
      }

      final cached = _CachedMetadata(
        title: data['title'],
        artist: data['artist'],
        album: data['album'],
        durationMs: data['duration'],
        artworkPath: artworkPath,
        artworkUri: data['artwork_uri'],
        dominantColor: data['dominant_color'],
        timestamp: data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      );

      // Hidratar memoria
      _memoryCache[key] = cached;
      return _convertToSongMetadata(cached);
    } catch (e) {
      print('[MetadataCache] Error reading cache: $e');
    }

    return null;
  }

  /// Convierte _CachedMetadata a SongMetadata
  static SongMetadata _convertToSongMetadata(_CachedMetadata cached) {
    return SongMetadata(
      title: cached.title ?? 'Unknown',
      artist: cached.artist ?? 'Unknown Artist',
      album: cached.album,
      durationMs: cached.durationMs,
      artworkPath: cached.artworkPath,
      artworkUri: cached.artworkUri,
      dominantColor: cached.dominantColor,
    );
  }

  /// Guardar metadata directamente
  static Future<void> saveFromMetadata({
    required String key,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    Uint8List? artworkData,
    String? artworkUri,
    int? dominantColor,
    String? filePath,
  }) async {
    try {
      final dbHelper = DatabaseHelper();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      String? savedArtworkPath;

      // 1. Guardar Imagen en Disco (FileSystem) SIN COMPRESIÓN
      if (artworkData != null && artworkData.isNotEmpty) {
        final dir = await getApplicationCacheDirectory();
        final safeKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

        // Usar TIMESTAMP en el nombre para evitar problemas de caché de imágenes
        final fileName = 'art_${safeKey}_$timestamp.jpg';
        final file = File('${dir.path}/$fileName');

        // Escribimos los bytes originales directamente
        await file.writeAsBytes(artworkData);
        savedArtworkPath = file.path;

        // Intentar borrar versiones antiguas de esta imagen para no llenar disco
        try {
          final oldPattern = RegExp('art_${safeKey}_.*\\.jpg');
          final files = dir.listSync();
          for (var f in files) {
            if (f is File &&
                f.path != savedArtworkPath &&
                f.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('art_${safeKey}_')) {
              try {
                await f.delete();
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      // 2. Guardar Texto + Path en SQLite
      final row = {
        'id': key,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': durationMs,
        'artwork_path': savedArtworkPath,
        'artwork_uri': artworkUri,
        'file_path': filePath,
        'dominant_color': dominantColor,
        'timestamp': timestamp,
      };

      await dbHelper.insertMetadata(row);

      // 3. Actualizar memoria (Solo rutas, sin bytes)
      _memoryCache[key] = _CachedMetadata(
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        artworkPath: savedArtworkPath,
        artworkUri: artworkUri,
        dominantColor: dominantColor,
        timestamp: timestamp,
      );
    } catch (e) {
      print('[MetadataCache] Error saving cache: $e');
    }
  }

  /// Eliminar una entrada específica del caché
  static Future<void> delete(String key) async {
    // 1. Eliminar de memoria
    _memoryCache.remove(key);

    try {
      // 2. Eliminar archivo de artwork
      final file = await _getCacheFile(key);
      if (await file.exists()) {
        await file.delete();
      }

      // 3. Eliminar metadata de SQLite
      final dbHelper = DatabaseHelper();
      await dbHelper.deleteMetadata(key);

      print('[MetadataCache] Deleted cache for key: $key');
    } catch (e) {
      print('[MetadataCache] Error deleting cache: $e');
    }
  }

  /// Limpiar caché (útil para debug o liberar espacio)
  static Future<void> clearCache() async {
    _memoryCache.clear();
    try {
      final dir = await getApplicationCacheDirectory();
      final files = dir.listSync();
      for (var f in files) {
        if (f is File && f.path.contains('art_')) {
          await f.delete();
        }
      }

      // Limpiar Tabla SQLite
      final dbHelper = DatabaseHelper();
      await dbHelper.clearAll();

      print('[MetadataCache] All cache cleared (Files + SQLite)');
    } catch (e) {
      print('[MetadataCache] Error clearing: $e');
    }
  }
}

/// Clase para almacenar metadata cacheada (Interna)
class _CachedMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? artworkPath; // Path al archivo en disco
  final String? artworkUri; // URI content://
  final int? dominantColor; // Color dominante cacheado
  final int timestamp; // Timestamp de cuando se guardó

  _CachedMetadata({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.artworkPath,
    this.artworkUri,
    this.dominantColor,
    required this.timestamp,
  });
}
