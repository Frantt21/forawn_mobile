// lib/services/music_library_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart'; // Necesario para ValueNotifier
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';
import '../services/metadata_service.dart';
import '../utils/id_generator.dart';

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
  static Future<List<Song>> scanFolder(
    String pathOrUri, {
    List<Song>? currentSongs,
    bool forceRefetchMetadata = false,
  }) async {
    final List<Song> songs = [];
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
          0.3,
        );

        final files = await SafHelper.listFilesFromTree(pathOrUri);

        if (files != null) {
          int processed = 0;
          final total = files.length;

          // FASE 1: Crear canciones básicas y cargar desde caché (RÁPIDO)
          for (final file in files) {
            final name = file['name'] ?? '';
            final uri = file['uri'] ?? '';

            if (uri.isNotEmpty &&
                existingMap.containsKey(uri) &&
                !forceRefetchMetadata) {
              // CASO 1: Canción ya existe -> REUTILIZAR
              songs.add(existingMap[uri]!);
            } else if (_isAudioFile(name) && uri.isNotEmpty) {
              // CASO 2: Canción NUEVA o REFRESH -> Crear con datos del caché
              var song = _createSongFromSaf(name, uri);

              // SIEMPRE intentar cargar desde caché (incluso en refresh)
              try {
                final cacheKey = IdGenerator.generateSongId(uri);
                final cached = await MusicMetadataCache.get(cacheKey);

                if (cached != null) {
                  song = song.copyWith(
                    title: cached.title,
                    artist: cached.artist,
                    album: cached.album,
                    duration: cached.durationMs != null
                        ? Duration(milliseconds: cached.durationMs!)
                        : null,
                    artworkPath: cached.artworkPath,
                    artworkUri: cached.artworkUri,
                    dominantColor: cached.dominantColor,
                  );
                }
              } catch (e) {
                print('[MusicLibrary] Cache read error: $e');
              }

              songs.add(song);
            }

            processed++;
            if (processed % 20 == 0) {
              loadingStatus.value = LibraryLoadingStatus(
                'Cargando ($processed/$total)...',
                0.3 + (0.4 * (processed / total)), // 30% a 70%
              );
              await Future.delayed(Duration.zero);
            }
          }

          print('[MusicLibrary] Loaded ${songs.length} songs from cache/basic');

          // FASE 2: Si es force reload, simplemente asegurar que todo tenga datos del caché
          // NO volvemos a extraer metadatos - eso ya se hizo en la carga inicial
          if (forceRefetchMetadata && songs.isNotEmpty) {
            loadingStatus.value = const LibraryLoadingStatus(
              'Finalizando...',
              0.9,
            );
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
                  // Cargar metadatos reales
                  final metadata = await MetadataService().loadMetadata(
                    id: song.id,
                    filePath: song.filePath,
                    forceReload: forceRefetchMetadata,
                    preserveColor: forceRefetchMetadata,
                  );

                  if (metadata != null) {
                    song = song.copyWith(
                      title: metadata.title,
                      artist: metadata.artist,
                      album: metadata.album,
                      duration: metadata.durationMs != null
                          ? Duration(milliseconds: metadata.durationMs!)
                          : null,
                      artworkPath: metadata.artworkPath,
                      artworkUri: metadata.artworkUri,
                      dominantColor: metadata.dominantColor,
                    );
                  }
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

      print('[MusicLibrary] Scan complete: ${songs.length} songs');
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
    String title = fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    String artist = 'Unknown Artist';

    if (fileName.contains(' - ')) {
      final parts = title.split(' - ');
      if (parts.length >= 2) {
        title = parts[0].trim();
        artist = parts.sublist(1).join(' - ').trim();
      }
    }

    return Song(
      id: IdGenerator.generateSongId(uri),
      title: title,
      artist: artist,
      filePath: uri,
    );
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
