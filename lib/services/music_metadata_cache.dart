import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audiotags/audiotags.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Servicio de caché persistente para metadata de música (FileSystem + SharedPrefs)
class MusicMetadataCache {
  // Caché en memoria para acceso rápido durante la sesión
  static final Map<String, _CachedMetadata> _memoryCache = {};

  /// Obtener archivo de caché para una key
  static Future<File> _getCacheFile(String key) async {
    final dir = await getApplicationCacheDirectory();
    // Usar hashcode para evitar problemas con caracteres especiales en rutas
    final fileName = 'art_${key.hashCode}.jpg';
    return File('${dir.path}/$fileName');
  }

  /// Obtener metadata del caché (memoria O disco)
  static Future<_CachedMetadata?> get(String key) async {
    // 1. Memoria
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }

    try {
      // 2. Disco
      final prefs = await SharedPreferences.getInstance();

      // Intentar leer texto (título, artista...)
      // Nota: Buscamos primero con el prefijo nuevo, si no, intentamos legacy?
      // Ignoremos legacy por simplicidad y robustez futura.
      final metaJson = prefs.getString('meta_txt_$key');

      Uint8List? artworkBytes;

      // Intentar leer imagen del sistema de archivos
      final file = await _getCacheFile(key);
      if (await file.exists()) {
        artworkBytes = await file.readAsBytes();
      }

      if (metaJson != null) {
        final data = json.decode(metaJson) as Map<String, dynamic>;
        final cached = _CachedMetadata(
          title: data['title'],
          artist: data['artist'],
          album: data['album'],
          durationMs: data['duration'],
          artworkBytes: artworkBytes,
        );

        // Hidratar memoria
        _memoryCache[key] = cached;
        return cached;
      } else if (artworkBytes != null) {
        // Solo imagen encontrada
        final cached = _CachedMetadata(artworkBytes: artworkBytes);
        _memoryCache[key] = cached;
        return cached;
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

      // Comprimir como JPEG con calidad 85
      final compressed = img.encodeJpg(resized, quality: 85);
      return Uint8List.fromList(compressed);
    } catch (e) {
      print('[MetadataCache] Error compressing artwork: $e');
      return null;
    }
  }

  /// Guardar metadata (AudioTags object wrapper)
  static Future<void> save(String key, Tag tag) async {
    Uint8List? artBytes;
    if (tag.pictures.isNotEmpty) {
      artBytes = tag.pictures.first.bytes;
    }

    await saveFromMetadata(
      key: key,
      title: tag.title,
      artist: tag.trackArtist ?? tag.albumArtist,
      album: tag.album,
      durationMs: tag.duration != null ? (tag.duration! * 1000).toInt() : null,
      artworkData: artBytes,
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
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Guardar Texto en SharedPrefs
      final data = {
        'title': title,
        'artist': artist,
        'album': album,
        'duration': durationMs,
      };
      await prefs.setString('meta_txt_$key', json.encode(data));

      // 2. Guardar Imagen en Disco (FileSystem)
      Uint8List? finalArtBytes;
      if (artworkData != null) {
        final compressed = _compressArtwork(artworkData);
        if (compressed != null) {
          final file = await _getCacheFile(key);
          await file.writeAsBytes(compressed);
          finalArtBytes = compressed;
        }
      }

      // 3. Actualizar memoria
      _memoryCache[key] = _CachedMetadata(
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        artworkBytes: finalArtBytes,
      );
    } catch (e) {
      print('[MetadataCache] Error saving cache: $e');
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

      // Limpiar prefs keys
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('meta_txt_'));
      for (var k in keys) {
        await prefs.remove(k);
      }
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
  final Uint8List? artworkBytes; // RAW bytes, no base64 string

  _CachedMetadata({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.artworkBytes,
  });

  // Getter de compatibilidad por si alguien llamaba .artwork
  Uint8List? get artwork => artworkBytes;
}
