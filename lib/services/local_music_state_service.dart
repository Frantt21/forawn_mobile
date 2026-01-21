// lib/services/local_music_state_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'music_library_service.dart';

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

  /// Inicializa el servicio - solo carga si no se ha cargado antes
  Future<void> init() async {
    if (_hasLoadedOnce) {
      print('[LocalMusicState] Already initialized, skipping...');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString('last_music_folder');

    if (lastPath != null) {
      await loadFolder(lastPath);
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
        currentSongs: forceReload ? _librarySongs : null,
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
