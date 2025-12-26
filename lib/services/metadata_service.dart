import 'dart:typed_data';
import 'package:audiotags/audiotags.dart';
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
    );
  }

  /// Carga con retry logic
  Future<SongMetadata?> _loadWithRetry({
    required String id,
    String? filePath,
    String? safUri,
    MetadataPriority priority = MetadataPriority.normal,
    int maxRetries = 3,
  }) async {
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final metadata = await _loadFromSource(
          filePath: filePath,
          safUri: safUri,
        );

        if (metadata != null) {
          // Guardar en caché persistente
          await MusicMetadataCache.saveFromMetadata(
            key: id,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            durationMs: metadata.durationMs,
            artworkData: metadata.artwork,
          );

          // Guardar en caché de memoria
          _addToMemoryCache(id, metadata);

          return metadata;
        }
      } catch (e) {
        print(
          '[MetadataService] Attempt ${attempt + 1}/$maxRetries failed: $e',
        );
        if (attempt < maxRetries - 1) {
          // Esperar antes de reintentar (backoff exponencial)
          await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
        }
      }
    }

    print(
      '[MetadataService] Failed to load metadata for $id after $maxRetries attempts',
    );
    return null;
  }

  /// Carga desde fuente (local o SAF)
  Future<SongMetadata?> _loadFromSource({
    String? filePath,
    String? safUri,
  }) async {
    if (safUri != null) {
      // Cargar desde SAF
      final metadata = await SafHelper.getMetadataFromUri(safUri);
      if (metadata != null) {
        return _convertMapToMetadata(metadata);
      }
    } else if (filePath != null) {
      // Cargar desde archivo local
      final tag = await AudioTags.read(filePath);
      if (tag != null) {
        return _convertTagToMetadata(tag, filePath);
      }
    }
    return null;
  }

  /// Convierte Map de SAF a SongMetadata
  SongMetadata _convertMapToMetadata(Map<String, dynamic> map) {
    return SongMetadata(
      title: map['title'] as String? ?? 'Unknown',
      artist: map['artist'] as String? ?? 'Unknown Artist',
      album: map['album'] as String?,
      durationMs: map['duration'] as int?,
      artwork: map['artwork'] as Uint8List?,
    );
  }

  /// Convierte Tag a SongMetadata
  SongMetadata _convertTagToMetadata(Tag tag, String filePath) {
    return SongMetadata(
      title: tag.title?.isNotEmpty == true
          ? tag.title!
          : _getFileNameWithoutExtension(filePath),
      artist: tag.trackArtist?.isNotEmpty == true
          ? tag.trackArtist!
          : 'Unknown Artist',
      album: tag.album,
      durationMs: tag.duration != null ? (tag.duration! * 1000).toInt() : null,
      artwork: tag.pictures.isNotEmpty ? tag.pictures.first.bytes : null,
    );
  }

  /// Obtiene nombre de archivo sin extensión
  String _getFileNameWithoutExtension(String path) {
    final fileName = path.split('/').last;
    final lastDot = fileName.lastIndexOf('.');
    return lastDot > 0 ? fileName.substring(0, lastDot) : fileName;
  }

  /// Carga en lote con priorización
  ///
  /// Carga múltiples metadatos de forma eficiente:
  /// - Ordena por prioridad
  /// - Carga en lotes de 5
  /// - Añade delays entre lotes para no bloquear UI
  Future<List<SongMetadata?>> loadBatch(
    List<MetadataLoadRequest> requests,
  ) async {
    // Ordenar por prioridad (high -> normal -> low)
    requests.sort((a, b) => b.priority.index.compareTo(a.priority.index));

    final results = <SongMetadata?>[];
    const batchSize = 5;

    for (var i = 0; i < requests.length; i += batchSize) {
      final end = (i + batchSize < requests.length)
          ? i + batchSize
          : requests.length;
      final batch = requests.sublist(i, end);

      // Cargar lote en paralelo
      final batchResults = await Future.wait(
        batch.map(
          (req) => loadMetadata(
            id: req.id,
            filePath: req.filePath,
            safUri: req.safUri,
            priority: req.priority,
          ),
        ),
      );

      results.addAll(batchResults);

      // Pequeño delay entre lotes para no saturar
      if (i + batchSize < requests.length) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    return results;
  }

  /// Añade metadatos al caché en memoria
  void _addToMemoryCache(String id, SongMetadata metadata) {
    // Si el caché está lleno, eliminar el más antiguo (FIFO)
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      final firstKey = _memoryCache.keys.first;
      _memoryCache.remove(firstKey);
    }

    _memoryCache[id] = metadata;
  }

  /// Limpia caché en memoria
  void clearMemoryCache() {
    _memoryCache.clear();
    print('[MetadataService] Memory cache cleared');
  }

  /// Limpia entrada específica del caché
  void clearCacheEntry(String id) {
    _memoryCache.remove(id);
  }

  /// Obtiene estadísticas del caché en memoria
  CacheStats getCacheStats() {
    int totalBytes = 0;

    for (var metadata in _memoryCache.values) {
      totalBytes += metadata.artwork?.length ?? 0;
      totalBytes += metadata.title.length * 2; // UTF-16
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
