import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audiotags/audiotags.dart';
import 'package:image/image.dart' as img;

/// Servicio de caché persistente para metadata de música
class MusicMetadataCache {
  // Caché en memoria para acceso rápido
  static final Map<String, _CachedMetadata> _memoryCache = {};

  /// Obtener metadata del caché (memoria o persistente)
  static Future<_CachedMetadata?> get(String key) async {
    // 1. Verificar caché en memoria
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }

    // 2. Verificar caché persistente
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('music_meta_$key');
      if (cachedJson != null) {
        try {
          final data = json.decode(cachedJson) as Map<String, dynamic>;
          final cached = _CachedMetadata(
            title: data['title'] as String?,
            artist: data['artist'] as String?,
            album: data['album'] as String?,
            durationMs: data['duration'] as int?,
            artworkBase64: data['art'] as String?,
          );

          // Guardar en memoria para próxima vez
          _memoryCache[key] = cached;
          return cached;
        } catch (e) {
          // Caché corrupto o antiguo sin title, eliminarlo
          print('[MetadataCache] Removing corrupted cache for key: $key');
          await prefs.remove('music_meta_$key');
        }
      }
    } catch (e) {
      print('[MetadataCache] Error reading cache: $e');
    }

    return null;
  }

  /// Comprimir imagen para almacenamiento eficiente
  static Uint8List? _compressArtwork(Uint8List originalBytes) {
    try {
      // Decodificar imagen
      final image = img.decodeImage(originalBytes);
      if (image == null) return null;

      // Redimensionar a máximo 300x300 (mantiene aspect ratio)
      final resized = img.copyResize(
        image,
        width: image.width > 300 ? 300 : image.width,
        height: image.height > 300 ? 300 : image.height,
        interpolation: img.Interpolation.average,
      );

      // Comprimir como JPEG con calidad 85 (buen balance calidad/tamaño)
      final compressed = img.encodeJpg(resized, quality: 85);

      print(
        '[MetadataCache] Compressed artwork: ${originalBytes.length} → ${compressed.length} bytes (${((1 - compressed.length / originalBytes.length) * 100).toStringAsFixed(1)}% reduction)',
      );

      return Uint8List.fromList(compressed);
    } catch (e) {
      print('[MetadataCache] Error compressing artwork: $e');
      return null;
    }
  }

  /// Guardar metadata en caché (memoria y persistente)
  static Future<void> save(String key, Tag tag) async {
    try {
      // Comprimir artwork si existe
      String? artBase64;
      if (tag.pictures != null && tag.pictures!.isNotEmpty) {
        final originalArtwork = tag.pictures!.first.bytes;
        final compressed = _compressArtwork(originalArtwork);
        if (compressed != null) {
          artBase64 = base64.encode(compressed);
        }
      }

      final cached = _CachedMetadata(
        title: tag.title,
        artist: tag.trackArtist ?? tag.albumArtist,
        album: tag.album,
        durationMs: tag.duration != null
            ? (tag.duration! * 1000).toInt()
            : null,
        artworkBase64: artBase64,
      );

      // Guardar en memoria
      _memoryCache[key] = cached;

      // Guardar en persistente
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'title': cached.title,
        'artist': cached.artist,
        'album': cached.album,
        'duration': cached.durationMs,
        'art': cached.artworkBase64,
      };
      await prefs.setString('music_meta_$key', json.encode(data));
    } catch (e) {
      print('[MetadataCache] Error saving cache: $e');
    }
  }

  /// Guardar metadata directamente desde datos (para SAF)
  static Future<void> saveFromMetadata({
    required String key,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    Uint8List? artworkData,
  }) async {
    try {
      // Comprimir artwork si existe
      String? artBase64;
      if (artworkData != null) {
        final compressed = _compressArtwork(artworkData);
        if (compressed != null) {
          artBase64 = base64.encode(compressed);
        }
      }

      final cached = _CachedMetadata(
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        artworkBase64: artBase64,
      );

      // Guardar en memoria
      _memoryCache[key] = cached;

      // Guardar en persistente
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'title': cached.title,
        'artist': cached.artist,
        'album': cached.album,
        'duration': cached.durationMs,
        'art': cached.artworkBase64,
      };
      await prefs.setString('music_meta_$key', json.encode(data));
      print('[MetadataCache] Saved metadata for key: $key');
    } catch (e) {
      print('[MetadataCache] Error saving cache: $e');
    }
  }

  /// Limpiar caché antiguo (opcional, para mantenimiento)
  static Future<void> clearOldCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('music_meta_')) {
          await prefs.remove(key);
        }
      }
      _memoryCache.clear();
    } catch (e) {
      print('[MetadataCache] Error clearing cache: $e');
    }
  }
}

/// Clase para almacenar metadata cacheada
class _CachedMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? artworkBase64;

  _CachedMetadata({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.artworkBase64,
  });

  Uint8List? get artwork {
    if (artworkBase64 == null || artworkBase64!.isEmpty) return null;
    try {
      return base64.decode(artworkBase64!);
    } catch (e) {
      return null;
    }
  }
}
