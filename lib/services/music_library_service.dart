// lib/services/music_library_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart'; // Necesario para ValueNotifier
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';
import '../services/metadata_service.dart';

class LibraryLoadingStatus {
  final String message;
  final double progress;
  const LibraryLoadingStatus(this.message, this.progress);
}

class MusicLibraryService {
  /// Notificador para actualizar UI cuando se cargan metadatos en background
  static final ValueNotifier<String?> onMetadataUpdated = ValueNotifier(null);

  /// Notificador de estado de carga global
  static final ValueNotifier<LibraryLoadingStatus> loadingStatus =
      ValueNotifier(const LibraryLoadingStatus('', 0.0));

  /// Escanea una carpeta en busca de canciones
  /// Soporta rutas normales y URIs de SAF (content://)
  /// Escanea una carpeta en busca de canciones
  /// Soporta rutas normales y URIs de SAF (content://)
  static Future<List<Song>> scanFolder(
    String pathOrUri, {
    List<Song>? currentSongs,
  }) async {
    final List<Song> songs = [];
    final List<Song> songsMissingMetadata = [];
    final Map<String, Song> existingMap = {};

    // Crear mapa de canciones existentes para búsqueda rápida O(1)
    if (currentSongs != null) {
      for (var s in currentSongs) {
        existingMap[s.filePath] = s;
      }
    }

    // Reset status
    loadingStatus.value = const LibraryLoadingStatus(
      'Iniciando escaneo...',
      0.0,
    );

    // Verificar permisos básicos si es ruta local
    if (!pathOrUri.startsWith('content://')) {
      if (!await _requestPermissions()) {
        print('[MusicLibrary] Permissions denied');
        return [];
      }
    }

    try {
      if (pathOrUri.startsWith('content://')) {
        // Modo SAF
        print('[MusicLibrary] Scanning SAF tree: $pathOrUri');
        loadingStatus.value = const LibraryLoadingStatus(
          'Leyendo archivos...',
          0.1,
        );

        final files = await SafHelper.listFilesFromTree(pathOrUri);

        if (files != null) {
          int processed = 0;
          final total = files.length;

          // FASE 1: Reutilizar existentes o Crear canciones CON caché (RÁPIDO)
          for (final file in files) {
            final name = file['name'] ?? '';
            final uri = file['uri'] ?? '';

            if (uri.isNotEmpty && existingMap.containsKey(uri)) {
              // CASO 1: Canción ya existe y cargada -> REUTILIZAR
              // Esto salta la lectura de caché y creación de objetos
              songs.add(existingMap[uri]!);
            } else if (_isAudioFile(name) && uri.isNotEmpty) {
              // CASO 2: Canción NUEVA o no cargada -> PROCESAR
              var song = _createSongFromSaf(name, uri);
              bool isCached = false;

              // Intentar cargar desde caché (rápido)
              try {
                final cacheKey = uri.hashCode.toString();
                final cached = await MusicMetadataCache.get(cacheKey);

                if (cached != null) {
                  // Usar datos del caché
                  song = song.copyWith(
                    title: cached.title ?? song.title,
                    artist: cached.artist ?? song.artist,
                    album: cached.album,
                    duration: cached.durationMs != null
                        ? Duration(milliseconds: cached.durationMs!)
                        : null,
                    artworkData: cached.artwork,
                    dominantColor: cached.dominantColor,
                  );
                  isCached = true;
                }
              } catch (e) {
                print('[MusicLibrary] Cache read error: $e');
              }

              songs.add(song);
              if (!isCached) {
                songsMissingMetadata.add(song);
              }
            }

            processed++;
            if (processed % 10 == 0) {
              loadingStatus.value = LibraryLoadingStatus(
                'Analizando archivos ($processed/$total)...',
                0.1 + (0.2 * (processed / total)), // 10% a 30%
              );
              // Ceder control a la UI para evitar congelamiento
              await Future.delayed(Duration.zero);
            }
          }

          print(
            '[MusicLibrary] Found ${songs.length} songs. Metadata missing for: ${songsMissingMetadata.length}',
          );

          // FASE 2: Cargar metadatos faltantes (Ahora esperamos para mostrar progreso)
          if (songsMissingMetadata.isNotEmpty) {
            await _loadMetadataInBackground(
              songsMissingMetadata,
              startProgress: 0.3,
            );

            // FASE 3: Actualizar la lista principal con los datos recién cacheados
            // Esto es crucial para que "Latest Favorites" y la Librería muestren artwork
            for (int i = 0; i < songs.length; i++) {
              // Yield every 50 updates to prevent freeze during list update
              if (i % 50 == 0) await Future.delayed(Duration.zero);

              if (songs[i].artworkData == null) {
                try {
                  final cacheKey = songs[i].filePath.hashCode.toString();
                  final cached = await MusicMetadataCache.get(cacheKey);
                  if (cached != null) {
                    songs[i] = songs[i].copyWith(
                      title: cached.title ?? songs[i].title,
                      artist: cached.artist ?? songs[i].artist,
                      album: cached.album,
                      duration: cached.durationMs != null
                          ? Duration(milliseconds: cached.durationMs!)
                          : songs[i].duration,
                      artworkData: cached.artwork,
                      dominantColor: cached.dominantColor,
                    );
                  }
                } catch (e) {
                  print(
                    '[MusicLibrary] Re-hydration error for ${songs[i].title}: $e',
                  );
                }
              }
            }
          }
        }
      } else {
        // Modo Sistema de Archivos Normal
        loadingStatus.value = const LibraryLoadingStatus(
          'Explorando directorio...',
          0.1,
        );
        print('[MusicLibrary] Scanning local directory: $pathOrUri');

        final dir = Directory(pathOrUri);
        if (await dir.exists()) {
          final entities = dir.listSync(recursive: false);
          int processed = 0;
          final total = entities.length;

          for (final entity in entities) {
            loadingStatus.value = LibraryLoadingStatus(
              'Leyendo archivo ${processed + 1}/$total...',
              0.1 + (0.8 * (processed / total)),
            );

            if (entity is File) {
              final name = entity.path.split(Platform.pathSeparator).last;
              if (_isAudioFile(name)) {
                var song = await Song.fromFile(entity);
                if (song != null) {
                  // Cargar metadatos (artwork, tags reales)
                  song = await song.loadMetadata();
                  songs.add(song);
                }
              }
            }
            processed++;
          }
        } else {
          print('[MusicLibrary] Directory does not exist: $pathOrUri');
        }
      }

      print('[MusicLibrary] Found ${songs.length} songs');
      // Ordenar alfabéticamente por título por defecto
      loadingStatus.value = const LibraryLoadingStatus('Finalizando...', 1.0);
      songs.sort((a, b) => a.title.compareTo(b.title));

      return songs;
    } catch (e) {
      print('[MusicLibrary] Error scanning folder: $e');
      return [];
    }
  }

  static bool _isAudioFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.aac');
  }

  static Song _createSongFromSaf(String fileName, String uri) {
    // Parseo básico del nombre de archivo (similar a Song.fromFile)
    String title = fileName.replaceAll(
      RegExp(r'\.[a-zA-Z0-9]+$'),
      '',
    ); // Quitar extensión
    String artist = 'Unknown Artist';

    if (fileName.contains(' - ')) {
      final parts = title.split(' - ');
      if (parts.length >= 2) {
        title = parts[0].trim();
        artist = parts.sublist(1).join(' - ').trim();
      }
    }

    return Song(
      id: uri.hashCode.toString(), // ID basado en URI hash
      title: title,
      artist: artist,
      filePath: uri, // Guardamos la Content URI como path
    );
  }

  /// Carga metadatos y espera a que termine (para mostrar diálogo de progreso)
  static Future<void> _loadMetadataInBackground(
    List<Song> songs, {
    double startProgress = 0.3,
  }) async {
    // Cargar en lotes de 5 para no saturar
    const batchSize = 5;
    final total = songs.length;
    int processed = 0;

    for (var i = 0; i < songs.length; i += batchSize) {
      final end = (i + batchSize < songs.length) ? i + batchSize : songs.length;
      final batch = songs.sublist(i, end);

      // Cargar lote en paralelo usando MetadataService
      await Future.wait(
        batch.map((song) async {
          try {
            final uri = song.filePath;
            final cacheKey = uri.hashCode.toString();
            final isSaf = uri.startsWith('content://');

            // Usar MetadataService que maneja MediaStore + caché automáticamente
            final metadata = await MetadataService().loadMetadata(
              id: cacheKey,
              safUri: isSaf ? uri : null,
              filePath: isSaf ? null : uri,
              priority: MetadataPriority
                  .high, // Alta prioridad ya que el usuario espera en el diálogo
            );

            if (metadata != null) {
              // 🔔 Notificar a la UI que esta canción tiene datos nuevos (artwork)
              onMetadataUpdated.value = uri;

              /* print(
                '[MusicLibrary] ✓ Cached metadata for: ${metadata.title} - ${metadata.artist}',
              ); */
            }
          } catch (e) {
            print('[MusicLibrary] Background metadata error: $e');
          }
        }),
      );

      processed += batch.length;

      // Actualizar progreso (de startProgress a 1.0)
      final currentBatchProgress = processed / total; // 0.0 a 1.0
      // Escalar al rango restante (1.0 - startProgress)
      final globalProgress =
          startProgress + (currentBatchProgress * (1.0 - startProgress));

      loadingStatus.value = LibraryLoadingStatus(
        'Procesando metadatos ($processed/$total)...',
        globalProgress,
      );

      // Pequeña pausa entre lotes para dar respiro a la UI
      await Future.delayed(const Duration(milliseconds: 10));
    }

    print('[MusicLibrary] ✓ All metadata loaded');
  }

  static Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.audio.request().isGranted) return true;
      if (await Permission.storage.request().isGranted) return true;
      // Android 13+
      if (await Permission.mediaLibrary.request().isGranted) return true;

      return false;
    }
    return true;
  }
}
