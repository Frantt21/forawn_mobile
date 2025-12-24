// lib/services/music_library_service.dart
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data'; // Para Uint8List
import '../models/song.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';

class MusicLibraryService {
  /// Escanea una carpeta en busca de canciones
  /// Soporta rutas normales y URIs de SAF (content://)
  static Future<List<Song>> scanFolder(String pathOrUri) async {
    final List<Song> songs = [];

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
        final files = await SafHelper.listFilesFromTree(pathOrUri);

        if (files != null) {
          // FASE 1: Crear canciones CON caché si existe (RÁPIDO)
          for (final file in files) {
            final name = file['name'] ?? '';
            final uri = file['uri'] ?? '';

            if (_isAudioFile(name) && uri.isNotEmpty) {
              var song = _createSongFromSaf(name, uri);

              // Intentar cargar desde caché (rápido)
              try {
                final cacheKey = uri.hashCode.toString();
                final cached = await MusicMetadataCache.get(cacheKey);

                if (cached != null) {
                  // Usar datos del caché (incluyendo title/artist que ahora son metadatos reales)
                  song = song.copyWith(
                    title: cached.title ?? song.title,
                    artist: cached.artist ?? song.artist,
                    album: cached.album,
                    duration: cached.durationMs != null
                        ? Duration(milliseconds: cached.durationMs!)
                        : null,
                    artworkData: cached.artwork,
                  );
                }
              } catch (e) {
                print('[MusicLibrary] Cache read error: $e');
              }

              songs.add(song);
            }
          }

          print(
            '[MusicLibrary] Found ${songs.length} songs (loading uncached metadata in background...)',
          );

          // FASE 2: Cargar metadatos faltantes en BACKGROUND
          _loadMetadataInBackground(songs);
        }
      } else {
        // Modo Sistema de Archivos Normal
        print('[MusicLibrary] Scanning local directory: $pathOrUri');
        final dir = Directory(pathOrUri);
        if (await dir.exists()) {
          // Listado recursivo? Por ahora no, solo nivel actual como piden "carpeta"
          // Cambiar a recursive: true si el usuario quiere subcarpetas
          final entities = dir.listSync(recursive: false);

          for (final entity in entities) {
            if (entity is File) {
              final name = entity.path.split(Platform.pathSeparator).last;
              if (_isAudioFile(name)) {
                var song = await Song.fromFile(entity);
                if (song != null) {
                  // Cargar metadatos (artwork, tags reales)
                  song = await song.loadMetadata();

                  if (song.artworkData != null) {
                    print(
                      '[MusicLibrary] ✓ Artwork loaded for ${song.title} (${song.artworkData!.length} bytes)',
                    );
                  } else {
                    print('[MusicLibrary] ⚠ No artwork for ${song.title}');
                  }

                  songs.add(song);
                }
              }
            }
          }
        } else {
          print('[MusicLibrary] Directory does not exist: $pathOrUri');
        }
      }

      print('[MusicLibrary] Found ${songs.length} songs');
      // Ordenar alfabéticamente por título por defecto
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

  /// Carga metadatos en background (no bloquea la UI)
  static void _loadMetadataInBackground(List<Song> songs) async {
    // Cargar en lotes de 5 para no saturar
    const batchSize = 5;

    for (var i = 0; i < songs.length; i += batchSize) {
      final end = (i + batchSize < songs.length) ? i + batchSize : songs.length;
      final batch = songs.sublist(i, end);

      // Cargar lote en paralelo
      await Future.wait(
        batch.map((song) async {
          try {
            final uri = song.filePath;
            final cacheKey = uri.hashCode.toString();

            // Verificar caché primero
            final cached = await MusicMetadataCache.get(cacheKey);

            if (cached != null) {
              return; // Ya está en caché
            }

            // Cargar desde Android y guardar en caché
            final metadata = await SafHelper.getMetadataFromUri(uri);
            if (metadata != null) {
              // Usar metadatos REALES del archivo, con fallback al nombre de archivo
              final realTitle = (metadata['title'] as String?)?.trim();
              final realArtist = (metadata['artist'] as String?)?.trim();

              // Usar metadatos reales si existen y no están vacíos, sino usar parseo del nombre
              final finalTitle = (realTitle != null && realTitle.isNotEmpty)
                  ? realTitle
                  : song.title;
              final finalArtist = (realArtist != null && realArtist.isNotEmpty)
                  ? realArtist
                  : song.artist;

              await MusicMetadataCache.saveFromMetadata(
                key: cacheKey,
                title: finalTitle,
                artist: finalArtist,
                album: metadata['album'] as String?,
                durationMs: metadata['duration'] as int?,
                artworkData: metadata['artworkData'] as Uint8List?,
              );
              print(
                '[MusicLibrary] ✓ Cached metadata for: $finalTitle - $finalArtist',
              );
            }
          } catch (e) {
            print('[MusicLibrary] Background metadata error: $e');
          }
        }),
      );

      // Pequeña pausa entre lotes para no saturar
      await Future.delayed(const Duration(milliseconds: 100));
    }

    print('[MusicLibrary] ✓ All metadata loaded in background');
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
