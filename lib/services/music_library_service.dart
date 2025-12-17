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
          for (final file in files) {
            final name = file['name'] ?? '';
            final uri = file['uri'] ?? '';

            if (_isAudioFile(name) && uri.isNotEmpty) {
              var song = _createSongFromSaf(name, uri);
              try {
                // Verificar caché primero
                final cacheKey = uri.hashCode.toString();
                final cached = await MusicMetadataCache.get(cacheKey);

                if (cached != null) {
                  // Usar datos del caché
                  print('[MusicLibrary] Using cached metadata for $name');
                  song = song.copyWith(
                    title: cached.title ?? song.title,
                    artist: cached.artist ?? song.artist,
                    album: cached.album,
                    duration: cached.durationMs != null
                        ? Duration(milliseconds: cached.durationMs!)
                        : null,
                    artworkData: cached.artwork,
                  );
                } else {
                  // Intentar cargar metadatos reales desde Android
                  final metadata = await SafHelper.getMetadataFromUri(uri);
                  if (metadata != null) {
                    print('[MusicLibrary] Metadata received for $name:');
                    print('  - title: ${metadata['title']}');
                    print('  - artist: ${metadata['artist']}');
                    print('  - album: ${metadata['album']}');
                    print('  - duration: ${metadata['duration']}');
                    print(
                      '  - artworkData: ${metadata['artworkData'] != null ? '${(metadata['artworkData'] as Uint8List).length} bytes' : 'null'}',
                    );

                    song = song.copyWith(
                      title: (metadata['title'] as String?)?.isNotEmpty == true
                          ? metadata['title']
                          : song.title,
                      artist:
                          (metadata['artist'] as String?)?.isNotEmpty == true
                          ? metadata['artist']
                          : song.artist,
                      album: metadata['album'] as String?,
                      duration: metadata['duration'] != null
                          ? Duration(milliseconds: metadata['duration'] as int)
                          : null,
                      artworkData: metadata['artworkData'] as Uint8List?,
                    );

                    // Guardar en caché para próxima vez
                    await MusicMetadataCache.saveFromMetadata(
                      key: cacheKey,
                      title: metadata['title'] as String?,
                      artist: metadata['artist'] as String?,
                      album: metadata['album'] as String?,
                      durationMs: metadata['duration'] as int?,
                      artworkData: metadata['artworkData'] as Uint8List?,
                    );

                    if (song.artworkData != null) {
                      print(
                        '[MusicLibrary] ✓ Artwork loaded for $name (${song.artworkData!.length} bytes)',
                      );
                    } else {
                      print('[MusicLibrary] ⚠ No artwork for $name');
                    }
                  }
                }
              } catch (e) {
                print('[MusicLibrary] Metadata error for $name: $e');
              }
              songs.add(song);
            }
          }
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
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      }
    }

    return Song(
      id: uri.hashCode.toString(), // ID basado en URI hash
      title: title,
      artist: artist,
      filePath: uri, // Guardamos la Content URI como path
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
