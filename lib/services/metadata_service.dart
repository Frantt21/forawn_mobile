// This tool call is just to verify SafHelper first.
// I will cancel this replacement and view SafHelper instead.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:palette_generator/palette_generator.dart';
import 'music_metadata_cache.dart';
import 'saf_helper.dart';

/// Prioridad de carga de metadatos
enum MetadataPriority {
  high, // Canciones visibles en pantalla
  normal, // Canciones en lista
  low, // Precarga
}

/// Request para carga de metadatos
class MetadataLoadRequest {
  final String id;
  final String? filePath;
  final String? safUri;
  final MetadataPriority priority;

  MetadataLoadRequest({
    required this.id,
    this.filePath,
    this.safUri,
    this.priority = MetadataPriority.normal,
  });
}

/// Estadísticas del caché en memoria
class CacheStats {
  final int memoryCacheSize;
  final int memoryUsageBytes;

  CacheStats({required this.memoryCacheSize, required this.memoryUsageBytes});

  String get memoryUsageFormatted {
    if (memoryUsageBytes < 1024) return '$memoryUsageBytes B';
    if (memoryUsageBytes < 1024 * 1024) {
      return '${(memoryUsageBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(memoryUsageBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Servicio centralizado para carga de metadatos
///
/// Características:
/// - Caché en memoria para acceso rápido
/// - Retry logic automático
/// - Priorización de carga
/// - Carga en lotes optimizada
/// - Manejo unificado de archivos locales y SAF
class MetadataService {
  static final MetadataService _instance = MetadataService._internal();
  factory MetadataService() => _instance;
  MetadataService._internal();

  // Caché en memoria para acceso rápido
  final Map<String, SongMetadata> _memoryCache = {};

  // Límite de caché en memoria (100 canciones)
  static const int _maxMemoryCacheSize = 100;

  // Stream para progreso de carga (mensaje, porcentaje 0-1)
  final _progressController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  /// Carga metadatos con prioridad y retry
  ///
  /// Parámetros:
  /// - [id]: ID único de la canción
  /// - [filePath]: Ruta del archivo local (opcional)
  /// - [safUri]: URI de SAF (opcional)
  /// - [priority]: Prioridad de carga
  /// - [forceReload]: Forzar recarga ignorando caché
  ///
  /// Retorna los metadatos o null si falla
  Future<SongMetadata?> loadMetadata({
    required String id,
    String? filePath,
    String? safUri,
    MetadataPriority priority = MetadataPriority.normal,
    bool forceReload = false,
  }) async {
    // 1. Verificar caché en memoria
    if (!forceReload && _memoryCache.containsKey(id)) {
      return _memoryCache[id];
    }

    // 2. Verificar caché persistente
    if (!forceReload) {
      final cached = await MusicMetadataCache.get(id);
      if (cached != null) {
        _addToMemoryCache(id, cached);
        return cached;
      }
    }

    // 3. Cargar desde archivo con retry
    return await _loadWithRetry(
      id: id,
      filePath: filePath,
      safUri: safUri,
      priority: priority,
      skipMediaStore: forceReload,
    );
  }

  /// Carga con retry logic

  /// Carga con retry logic
  Future<SongMetadata?> _loadWithRetry({
    required String id,
    String? filePath,
    String? safUri,
    MetadataPriority priority = MetadataPriority.normal,
    int maxRetries = 3,
    bool skipMediaStore = false,
  }) async {
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final rawMetadata = await _loadFromSource(
          filePath: filePath,
          safUri: safUri,
          skipMediaStore: skipMediaStore,
        );

        if (rawMetadata != null) {
          // Extraer color dominante del artwork (si existe)
          int? dominantColor;

          // Guardar artwork en disco si viene como bytes crudos
          Uint8List? artworkBytes = rawMetadata['artworkBytes'];

          if (artworkBytes != null && artworkBytes.isNotEmpty) {
            dominantColor = await _extractDominantColor(artworkBytes);
          }

          // Guardar en caché persistente (incluyendo color)
          // Esto guardará los bytes en disco y nos despreocuparemos de ellos en RAM
          await MusicMetadataCache.saveFromMetadata(
            key: id,
            title: rawMetadata['title'],
            artist: rawMetadata['artist'],
            album: rawMetadata['album'],
            durationMs: rawMetadata['durationMsg'],
            artworkData: artworkBytes, // Se guarda en disco y se libera
            artworkUri: rawMetadata['artworkUri'],
            dominantColor: dominantColor,
          );

          // Cargar desde caché para obtener la RUTA del archivo, no los bytes
          final cachedMetadata = await MusicMetadataCache.get(id);

          if (cachedMetadata != null) {
            _addToMemoryCache(id, cachedMetadata);
            return cachedMetadata;
          }
        }
      } catch (e) {
        print(
          '[MetadataService] Attempt ${attempt + 1}/$maxRetries failed: $e',
        );
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
        }
      }
    }

    print(
      '[MetadataService] Failed to load metadata for $id after $maxRetries attempts',
    );
    return null;
  }

  /// Carga desde fuente (local o SAF) y devuelve un Map temporal con bytes
  /// NO devuelve SongMetadata porque SongMetadata ya no soporta bytes
  Future<Map<String, dynamic>?> _loadFromSource({
    String? filePath,
    String? safUri,
    bool skipMediaStore = false,
  }) async {
    // ... Implementación similar pero devolviendo Map ...
    // Para simplificar, usamos _convertMapToRawMap que normaliza los datos

    if (safUri != null) {
      final metadata = await SafHelper.getMetadataFromUri(safUri);
      if (metadata != null) return _normalizeMetadataMap(metadata);
    } else if (filePath != null) {
      if (!skipMediaStore) {
        final mediaStoreData = await SafHelper.getMetadataFromMediaStore(
          filePath,
        );
        if (mediaStoreData != null) {
          var normalized = _normalizeMetadataMap(mediaStoreData);

          // Cargar bytes si hace falta
          if (normalized['artworkBytes'] == null &&
              normalized['artworkUri'] != null) {
            try {
              final bytes = await SafHelper.readBytesFromUri(
                normalized['artworkUri'],
                maxBytes: 200 * 1024,
              );
              if (bytes != null) {
                normalized['artworkBytes'] = bytes;
              }
            } catch (e) {
              print('[MetadataService] Error reading art bytes: $e');
            }
          }
          return normalized;
        }
      }

      // Fallback File
      if (File(filePath).existsSync()) {
        final fileUri = Uri.file(filePath).toString();
        final metadataMap = await SafHelper.getMetadataFromUri(fileUri);
        if (metadataMap != null) return _normalizeMetadataMap(metadataMap);
      }
    }
    return null;
  }

  Map<String, dynamic> _normalizeMetadataMap(Map<String, dynamic> map) {
    return {
      'title': map['title'] as String? ?? 'Unknown',
      'artist': map['artist'] as String? ?? 'Unknown Artist',
      'album': map['album'] as String?,
      'durationMs': map['duration'] is int
          ? map['duration'] as int
          : (map['duration'] is String ? int.tryParse(map['duration']) : null),
      'artworkBytes': map['artworkData'] as Uint8List?,
      'artworkUri': map['artworkUri'] as String?,
    };
  }

  Future<int?> _extractDominantColor(Uint8List artworkBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        artworkBytes,
        targetWidth: 20,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final paletteGenerator = await PaletteGenerator.fromImage(
        image,
        maximumColorCount: 16,
      );

      final dominantColor =
          paletteGenerator.dominantColor?.color ??
          paletteGenerator.vibrantColor?.color;

      return dominantColor?.value;
    } catch (e) {
      return null;
    }
  }

  Future<void> loadBatch(List<MetadataLoadRequest> requests) async {
    // Agrupar por prioridad
    final highPriority = requests
        .where((r) => r.priority == MetadataPriority.high)
        .toList();
    final normalPriority = requests
        .where((r) => r.priority == MetadataPriority.normal)
        .toList();
    final lowPriority = requests
        .where((r) => r.priority == MetadataPriority.low)
        .toList();

    // Procesar en orden
    await _processBatch(highPriority);
    await _processBatch(normalPriority);
    await _processBatch(lowPriority);
  }

  Future<void> _processBatch(List<MetadataLoadRequest> batch) async {
    for (final request in batch) {
      await loadMetadata(
        id: request.id,
        filePath: request.filePath,
        safUri: request.safUri,
        priority: request.priority,
      );
    }
  }

  /// Limpiar entrada específica del caché
  Future<void> clearCacheEntry(String id) async {
    _memoryCache.remove(id);
    await MusicMetadataCache.delete(id);
  }

  /// Limpiar todo el caché
  Future<void> clearAllCaches() async {
    _memoryCache.clear();
    await MusicMetadataCache.clearCache();
  }

  /// Añade metadatos al caché en memoria
  void _addToMemoryCache(String id, SongMetadata metadata) {
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      final firstKey = _memoryCache.keys.first;
      _memoryCache.remove(firstKey);
    }
    _memoryCache[id] = metadata;
  }

  // ... clear methods ...

  /// Obtiene estadísticas del caché en memoria
  CacheStats getCacheStats() {
    int totalBytes = 0;

    for (var metadata in _memoryCache.values) {
      // Ahora sumamos longitud de strings, mucho menos que bytes de imagen
      totalBytes += (metadata.artworkPath?.length ?? 0) * 2;
      totalBytes += metadata.title.length * 2;
      totalBytes += metadata.artist.length * 2;
      totalBytes += (metadata.album?.length ?? 0) * 2;
    }

    return CacheStats(
      memoryCacheSize: _memoryCache.length,
      memoryUsageBytes: totalBytes,
    );
  }

  /// Precarga metadatos en segundo plano
  ///
  /// Útil para precargar canciones que probablemente se verán pronto
  Future<void> preloadMetadata(List<MetadataLoadRequest> requests) async {
    // Marcar todas como baja prioridad
    final lowPriorityRequests = requests
        .map(
          (req) => MetadataLoadRequest(
            id: req.id,
            filePath: req.filePath,
            safUri: req.safUri,
            priority: MetadataPriority.low,
          ),
        )
        .toList();

    // Cargar en segundo plano sin esperar
    loadBatch(lowPriorityRequests)
        .then((_) {
          print(
            '[MetadataService] Preloaded ${requests.length} metadata entries',
          );
        })
        .catchError((e) {
          print('[MetadataService] Error preloading: $e');
        });
  }

  /// Verifica si los metadatos están en caché
  Future<bool> isInCache(String id) async {
    if (_memoryCache.containsKey(id)) return true;
    final cached = await MusicMetadataCache.get(id);
    return cached != null;
  }
}
