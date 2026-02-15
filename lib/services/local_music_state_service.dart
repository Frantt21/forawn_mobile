// lib/services/local_music_state_service.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'music_library_service.dart';
import '../services/music_metadata_cache.dart';
import '../utils/id_generator.dart';

/// Servicio singleton que mantiene el estado de la música local
/// Persiste los datos aunque el screen se destruya y reconstruya
class LocalMusicStateService extends ChangeNotifier {
  static final LocalMusicStateService _instance =
      LocalMusicStateService._internal();

  factory LocalMusicStateService() => _instance;

  LocalMusicStateService._internal();

  // Estado persistente
  List<Song> _librarySongs = [];
  bool _isLoading = false;
  bool _hasLoadedOnce = false;
  String? _currentFolderPath;

  // Getters
  List<Song> get librarySongs => _librarySongs;
  bool get isLoading => _isLoading;
  bool get hasLoadedOnce => _hasLoadedOnce;
  String? get currentFolderPath => _currentFolderPath;

  /// Inicializa el servicio
  Future<void> init() async {
    if (_hasLoadedOnce) {
      print('[LocalMusicState] Already initialized, skipping...');
      return;
    }

    // Solo configurar listeners. NO cargar carpetas automáticamente aquí.
    // La carga se debe disparar desde la UI (LocalMusicScreen) para asegurar
    // que el contexto esté listo para pedir permisos si es necesario.

    // Escuchar actualizaciones de metadatos en segundo plano
    MusicLibraryService.onMetadataUpdated.addListener(_onMetadataUpdated);
  }

  void _onMetadataUpdated() async {
    final uri = MusicLibraryService.onMetadataUpdated.value;
    if (uri != null && _librarySongs.isNotEmpty) {
      int index = _librarySongs.indexWhere((s) => s.filePath == uri);

      // Fallback: Try matching decoded URI if exact match fails
      if (index == -1) {
        try {
          final decodedUri = Uri.decodeFull(uri);
          index = _librarySongs.indexWhere(
            (s) => Uri.decodeFull(s.filePath) == decodedUri,
          );
        } catch (e) {
          print('[LocalMusicState] Error decoding URI: $e');
        }
      }

      if (index != -1) {
        try {
          final cacheKey = IdGenerator.generateSongId(uri);
          final cached = await MusicMetadataCache.get(cacheKey);

          if (cached != null) {
            // IMPORTANT: Evict old image from Flutter's cache
            if (cached.artworkPath != null) {
              try {
                final file = File(cached.artworkPath!);
                if (file.existsSync()) {
                  final fileImage = FileImage(file);
                  fileImage.evict();
                  print(
                    '[LocalMusicState] Evicted image cache for updated song',
                  );
                }
              } catch (e) {
                print('[LocalMusicState] Error evicting image: $e');
              }
            }

            final currentSong = _librarySongs[index];
            final updatedSong = currentSong.copyWith(
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

            _librarySongs[index] = updatedSong;
            notifyListeners();
            print(
              '[LocalMusicState] Song metadata updated: ${updatedSong.title}',
            );
          }
        } catch (e) {
          print('[LocalMusicState] Error updating song metadata: $e');
        }
      }
    }
  }

  /// Carga una carpeta - puede ser llamado manualmente o en refresh
  Future<void> loadFolder(String path, {bool forceReload = false}) async {
    // Si ya está cargada la misma carpeta y no es force reload, skip
    if (_currentFolderPath == path && _hasLoadedOnce && !forceReload) {
      print('[LocalMusicState] Folder already loaded, skipping...');
      return;
    }

    _isLoading = true;
    _currentFolderPath = path;
    notifyListeners();

    try {
      final songs = await MusicLibraryService.scanFolder(
        path,
        // IMPORTANTE: Si es forceReload, NO pasar currentSongs
        // Esto fuerza la recarga de metadatos desde el caché
        currentSongs: forceReload ? null : _librarySongs,
        forceRefetchMetadata: forceReload,
      );

      _librarySongs = songs;
      _hasLoadedOnce = true;

      // Guardar la ruta en preferencias
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_music_folder', path);

      print('[LocalMusicState] Loaded ${songs.length} songs from $path');
    } catch (e) {
      print('[LocalMusicState] Error loading folder: $e');
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refresca la carpeta actual (para pull-to-refresh)
  Future<void> refresh() async {
    if (_currentFolderPath != null) {
      print('[LocalMusicState] Refreshing current folder...');
      await loadFolder(_currentFolderPath!, forceReload: true);
    }
  }

  /// Actualiza una canción específica (cuando llegan metadatos en background)
  void updateSong(String filePath, Song updatedSong) {
    final index = _librarySongs.indexWhere((s) => s.filePath == filePath);
    if (index != -1) {
      _librarySongs[index] = updatedSong;
      notifyListeners();
    }
  }

  /// Limpia el estado (útil para testing o logout)
  void clear() {
    _librarySongs = [];
    _hasLoadedOnce = false;
    _currentFolderPath = null;
    _isLoading = false;
    notifyListeners();
  }
}
