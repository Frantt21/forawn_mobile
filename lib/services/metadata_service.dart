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

  void _notifyProgress(String message, double? progress) {
    _progressController.add({'message': message, 'progress': progress});
  }

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
        final metadata = await _loadFromSource(
          filePath: filePath,
          safUri: safUri,
          skipMediaStore: skipMediaStore,
        );

        if (metadata != null) {
          // Extraer color dominante del artwork (si existe)
          int? dominantColor;
          if (metadata.artwork != null) {
            dominantColor = await _extractDominantColor(metadata.artwork!);
          }

          // Guardar en caché persistente (incluyendo color)
          await MusicMetadataCache.saveFromMetadata(
            key: id,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            durationMs: metadata.durationMs,
            artworkData: metadata.artwork,
            artworkUri: metadata.artworkUri,
            dominantColor: dominantColor,
          );

          // Crear metadata con color y guardar en memoria
          final metadataWithColor = SongMetadata(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            durationMs: metadata.durationMs,
            artwork: metadata.artwork,
            artworkUri: metadata.artworkUri,
            dominantColor: dominantColor,
          );
          _addToMemoryCache(id, metadataWithColor);

          return metadataWithColor;
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
    bool skipMediaStore = false,
  }) async {
    print(
      '[MetadataService] Loading from: filePath=$filePath, safUri=$safUri, skipMediaStore=$skipMediaStore',
    );

    if (safUri != null) {
      // Cargar desde SAF
      print('[MetadataService] Using SAF path: $safUri');
      final metadata = await SafHelper.getMetadataFromUri(safUri);
      if (metadata != null) {
        final result = _convertMapToMetadata(metadata);
        print(
          '[MetadataService] SAF metadata loaded, has artwork: ${result.artwork != null}',
        );
        return result;
      }
    } else if (filePath != null) {
      // Intentar primero con MediaStore (Mucho más rápido) - SOLO SI NO se solicita skip
      if (!skipMediaStore) {
        print('[MetadataService] Trying MediaStore for: $filePath');
        final mediaStoreData = await SafHelper.getMetadataFromMediaStore(
          filePath,
        );
        if (mediaStoreData != null) {
          // Encontrado en MediaStore!
          print('[MetadataService] MediaStore found data');
          var metadata = _convertMapToMetadata(mediaStoreData);
          print(
            '[MetadataService] Has artworkUri: ${metadata.artworkUri}, has artwork bytes: ${metadata.artwork != null}',
          );

          // Si tenemos URI pero no bytes, cargar los bytes del thumbnail
          if (metadata.artwork == null && metadata.artworkUri != null) {
            print(
              '[MetadataService] Loading artwork bytes from URI: ${metadata.artworkUri}',
            );
            try {
              final bytes = await SafHelper.readBytesFromUri(
                metadata.artworkUri!,
                maxBytes: 200 * 1024, // Thumbnail
              );
              print(
                '[MetadataService] Loaded ${bytes?.length ?? 0} bytes of artwork',
              );
              if (bytes != null && bytes.isNotEmpty) {
                metadata = SongMetadata(
                  title: metadata.title,
                  artist: metadata.artist,
                  album: metadata.album,
                  durationMs: metadata.durationMs,
                  artwork: bytes,
                  artworkUri: metadata.artworkUri,
                );
                print('[MetadataService] ✓ Artwork loaded successfully');
              } else {
                print('[MetadataService] ✗ No artwork bytes received');
              }
            } catch (e) {
              print('[MetadataService] ✗ Error loading art bytes: $e');
            }
          }
          return metadata;
        } else {
          print('[MetadataService] MediaStore returned null, trying fallback');
        }
      } // Ends if (!skipMediaStore)

      // Fallback: Leer archivo usando el método nativo (SafHelper puede leer file:// URIs)
      try {
        if (File(filePath).existsSync()) {
          print('[MetadataService] Using fallback file:// method');
          // Convertir ruta de archivo a URI file://
          final fileUri = Uri.file(filePath).toString();
          final metadataMap = await SafHelper.getMetadataFromUri(fileUri);

          if (metadataMap != null) {
            final result = _convertMapToMetadata(metadataMap);
            print(
              '[MetadataService] Fallback loaded, has artwork: ${result.artwork != null}',
            );
            return result;
          }
        }
      } catch (e) {
        print(
          '[MetadataService] Error reading local file metadata fallback: $e',
        );
      }
    }
    print('[MetadataService] ✗ No metadata loaded');
    return null;
  }

  /// Convierte Map de SAF/MediaStore a SongMetadata
  SongMetadata _convertMapToMetadata(Map<String, dynamic> map) {
    return SongMetadata(
      title: map['title'] as String? ?? 'Unknown',
      artist: map['artist'] as String? ?? 'Unknown Artist',
      album: map['album'] as String?,
      durationMs: map['duration'] is int
          ? map['duration'] as int
          : (map['duration'] is String ? int.tryParse(map['duration']) : null),
      artwork:
          map['artworkData'] as Uint8List?, // Nativo devuelve 'artworkData'
      artworkUri: map['artworkUri'] as String?, // MediaStore devuelve URI
    );
  }

  /// Extrae el color dominante del artwork
  Future<int?> _extractDominantColor(Uint8List artworkBytes) async {
    try {
      print(
        '[MetadataService] Extracting dominant color for image of size: ${artworkBytes.length}',
      );
      // Decodificar imagen
      final codec = await ui.instantiateImageCodec(artworkBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Generar paleta
      final paletteGenerator = await PaletteGenerator.fromImage(
        image,
        maximumColorCount: 16, // Reducido para mejor rendimiento
      );

      // Obtener color dominante o vibrante
      final dominantColor =
          paletteGenerator.dominantColor?.color ??
          paletteGenerator.vibrantColor?.color;

      print(
        '[MetadataService] Dominant color extracted: ${dominantColor?.value.toRadixString(16)}',
      );
      return dominantColor?.value;
    } catch (e) {
      print('[MetadataService] Error extracting dominant color: $e');
      return null;
    }
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

      // Notificar progreso
      final progress = results.length / requests.length;
      _notifyProgress(
        'Optimizando experiencia... ${(progress * 100).toInt()}%',
        progress,
      );

      // Pequeño delay entre lotes para no saturar
      if (i + batchSize < requests.length) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    _notifyProgress('¡Listo!', 1.0);
    // Ocultar mensaje después de un tiempo
    Future.delayed(const Duration(seconds: 2), () {
      _notifyProgress('', null);
    });

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

  /// Limpia TODOS los cachés (Memoria + Disco)
  Future<void> clearAllCaches() async {
    // 1. Limpiar memoria local
    clearMemoryCache();

    // 2. Limpiar caché persistente y estático
    await MusicMetadataCache.clearCache();

    print('[MetadataService] All caches cleared (Memory + Disk)');
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
