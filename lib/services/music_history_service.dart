import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/music_library_service.dart';

class MusicHistoryService extends ChangeNotifier {
  static final MusicHistoryService _instance = MusicHistoryService._internal();
  factory MusicHistoryService() => _instance;
  MusicHistoryService._internal();

  static const String _key = 'music_history';
  static const int _maxHistory = 50;

  List<Song> _history = [];

  List<Song> get history => List.unmodifiable(_history);

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _checkAndMigrate();
    await _loadHistory();

    // Escuchar actualizaciones de metadatos en segundo plano
    MusicLibraryService.onMetadataUpdated.addListener(_onMetadataUpdated);

    _initialized = true;
  }

  void _onMetadataUpdated() async {
    final uri = MusicLibraryService.onMetadataUpdated.value;
    if (uri != null && _history.isNotEmpty) {
      final index = _history.indexWhere((s) => s.filePath == uri);
      if (index != -1) {
        // Hydrate from cache
        final dbHelper = DatabaseHelper();
        final cacheKey = uri.hashCode.toString();
        final metadata = await dbHelper.getMetadata(cacheKey);

        if (metadata != null) {
          final currentSong = _history[index];
          final updatedSong = currentSong.copyWith(
            title: metadata['title'],
            artist: metadata['artist'],
            album: metadata['album'],
            duration: metadata['duration'] != null
                ? Duration(milliseconds: metadata['duration'])
                : null,
            artworkPath: metadata['artwork_path'],
            artworkUri: metadata['artwork_uri'],
            dominantColor: metadata['dominant_color'],
          );

          _history[index] = updatedSong;
          notifyListeners();
        }
      }
    }
  }

  /// Migración única de SharedPreferences a SQLite
  Future<void> _checkAndMigrate() async {
    try {
      final dbHelper = DatabaseHelper();
      final existingHistory = await dbHelper.getPlaybackHistory(limit: 1);

      if (existingHistory.isNotEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString(_key);

      if (jsonString != null) {
        print('[MusicHistory] Migrating history to SQLite...');
        final List<dynamic> jsonList = json.decode(jsonString);
        // Validar y procesar desde el final para mantener orden cronológico al insertar
        // (Aunque getPlaybackHistory ordena por timestamp DESC, aquí simulamos inserción)

        for (final item in jsonList) {
          final song = Song.fromJson(item);
          if (song.filePath.isNotEmpty) {
            // 1. Guardar Metadata
            await dbHelper.insertMetadata({
              'id': song.id,
              'title': song.title,
              'artist': song.artist,
              'album': song.album,
              'duration': song.duration?.inMilliseconds,
              'file_path': song.filePath,
              'artwork_path': song.artworkPath,
              'artwork_uri': song.artworkUri,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              // No artwork bytes here to save space/time during migration
            });

            // 2. Guardar en Historial
            await dbHelper.addToPlaybackHistory(song.id);
          }
        }
        print('[MusicHistory] History migration complete.');
      }
    } catch (e) {
      print('[MusicHistory] Error during migration: $e');
    }
  }

  Future<void> _loadHistory() async {
    try {
      final dbHelper = DatabaseHelper();
      final songIds = await dbHelper.getPlaybackHistory(limit: _maxHistory);

      final List<Song> loadedSongs = [];

      for (final id in songIds) {
        final metadata = await dbHelper.getMetadata(id);
        if (metadata != null && metadata['file_path'] != null) {
          loadedSongs.add(
            Song(
              id: metadata['id'],
              title: metadata['title'] ?? 'Unknown',
              artist: metadata['artist'] ?? 'Unknown Artist',
              album: metadata['album'],
              duration: metadata['duration'] != null
                  ? Duration(milliseconds: metadata['duration'])
                  : null,
              filePath: metadata['file_path'],
              artworkPath: metadata['artwork_path'],
              artworkUri: metadata['artwork_uri'],
              dominantColor: metadata['dominant_color'],
            ),
          );
        }
      }

      _history = loadedSongs;
      notifyListeners();
    } catch (e) {
      print('[MusicHistory] Error loading history: $e');
    }
  }

  Future<void> addToHistory(Song song) async {
    // Optimistic update
    _history.removeWhere((s) => s.id == song.id);
    _history.insert(0, song);
    if (_history.length > _maxHistory) {
      _history = _history.sublist(0, _maxHistory);
    }
    notifyListeners();

    try {
      final dbHelper = DatabaseHelper();

      // Ensure metadata exists
      await dbHelper.insertMetadata({
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'album': song.album,
        'duration': song.duration?.inMilliseconds,
        'file_path': song.filePath,
        'artwork_path': song.artworkPath,
        'artwork_uri': song.artworkUri,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'dominant_color': song.dominantColor,
      });

      await dbHelper.addToPlaybackHistory(song.id);
    } catch (e) {
      print('[MusicHistory] Error saving history: $e');
    }
  }

  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await DatabaseHelper().clearPlaybackHistory();

    // Also clear prefs just in case
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
