import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/music_library_service.dart';
import '../utils/id_generator.dart';

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
        // FIX: Use stable ID generator instead of random hashCode
        final cacheKey = IdGenerator.generateSongId(uri);
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
      print(
        '[MusicHistory] DEBUG: Loaded ${songIds.length} RAW IDs from DB playback_history',
      );

      final List<Song> loadedSongs = [];
      final Set<String> processedIds = {};

      for (final id in songIds) {
        final metadata = await dbHelper.getMetadata(id);

        // Debugging detailed state
        if (metadata != null) {
          print(
            '[MusicHistory] DEBUG: ID $id found. Path: ${metadata['file_path']}',
          );
        } else {
          print('[MusicHistory] DEBUG: ID $id metadata is NULL');
        }

        if (metadata == null) {
          print(
            '[MusicHistory] Metadata COMPLETELY MISSING for ID: $id. Auto-cleaning.',
          );
          await dbHelper.deleteFromPlaybackHistory(id);
          continue;
        }

        // If metadata exists but path is missing, we try to survive if we have at least a title
        // But without path we can't play it.
        // Let's NOT delete it immediately if we think we can recover it later,
        // OR we just hide it from the list but keep ID in DB?
        // For now, let's just Log and Skip adding to list, but NOT delete from DB yet?
        // NO, if we lack path, the UI will crash or be useless.
        // Let's delete for now but ONLY if file_path is indeed null.

        if (metadata['file_path'] == null) {
          print(
            '[MusicHistory] Metadata CORRUPT (Missing Path) for ID: $id. Cleaning.',
          );
          await dbHelper.deleteFromPlaybackHistory(id);
          // Also clean corrupt metadata row so it can be re-inserted cleanly later
          await dbHelper.deleteMetadata(id);
          continue;
        }

        final filePath = metadata['file_path'];
        final storedId = metadata['id'];

        // Verificar si el ID almacenado coincide con el generador estable
        final stableId = IdGenerator.generateSongId(filePath);

        String finalId = storedId;

        // Migración on-the-fly: Si detectamos un ID antiguo/aleatorio
        if (storedId != stableId) {
          print('[MusicHistory] Migrating legacy ID $storedId to $stableId');
          await dbHelper.migrateLegacySongId(storedId, stableId);
          finalId = stableId;
        }

        if (processedIds.contains(finalId)) {
          print('[MusicHistory] Duplicate ID skipped: $finalId');
          continue;
        }
        processedIds.add(finalId);

        // print(
        //   '[MusicHistory] Loaded history item: $finalId (${metadata['title']})',
        // );

        loadedSongs.add(
          Song(
            id: finalId,
            title: metadata['title'] ?? 'Unknown',
            artist: metadata['artist'] ?? 'Unknown Artist',
            album: metadata['album'],
            duration: metadata['duration'] != null
                ? Duration(milliseconds: metadata['duration'])
                : null,
            filePath: filePath,
            artworkPath: metadata['artwork_path'],
            artworkUri: metadata['artwork_uri'],
            dominantColor: metadata['dominant_color'],
          ),
        );
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

      // Check existing metadata to avoid overwriting valid data with "Unknown"
      final existingMap = await dbHelper.getMetadata(song.id);
      Map<String, dynamic> metadataToSave;

      if (existingMap != null) {
        // Merge strategy: Keep existing if new is "Unknown", but update if new is valid
        // Always update file_path to ensure playability
        metadataToSave = Map<String, dynamic>.from(existingMap);

        // Update fields if the new song has better data
        if (song.title != 'Unknown' && song.title.isNotEmpty) {
          metadataToSave['title'] = song.title;
        }
        if (song.artist != 'Unknown Artist' &&
            song.artist != 'Unknown' &&
            song.artist.isNotEmpty) {
          metadataToSave['artist'] = song.artist;
        }
        if (song.album != null &&
            song.album != 'Unknown' &&
            song.album!.isNotEmpty) {
          metadataToSave['album'] = song.album;
        }
        if (song.duration != null) {
          metadataToSave['duration'] = song.duration!.inMilliseconds;
        }
        // Always update path and uri if available
        if (song.filePath.isNotEmpty) {
          metadataToSave['file_path'] = song.filePath;
        }
        if (song.artworkUri != null) {
          metadataToSave['artwork_uri'] = song.artworkUri;
        }
        if (song.artworkPath != null) {
          metadataToSave['artwork_path'] = song.artworkPath;
        }
        if (song.dominantColor != null) {
          metadataToSave['dominant_color'] = song.dominantColor;
        }

        metadataToSave['timestamp'] = DateTime.now().millisecondsSinceEpoch;
      } else {
        // New entry
        metadataToSave = {
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
        };
      }

      await dbHelper.insertMetadata(metadataToSave);
      await dbHelper.addToPlaybackHistory(song.id);

      print(
        '[MusicHistory] Saved to history DB: ${song.id} - ${metadataToSave['title']}',
      );
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

  /// Actualizar un item específico del historial con metadata fresca
  Future<void> updateHistoryItem(Song updatedSong) async {
    final index = _history.indexWhere((s) => s.id == updatedSong.id);
    if (index != -1) {
      _history[index] = updatedSong;
      notifyListeners();

      // Also ensure this fresh metadata is persisted to DB
      try {
        final dbHelper = DatabaseHelper();
        await dbHelper.insertMetadata({
          'id': updatedSong.id,
          'title': updatedSong.title,
          'artist': updatedSong.artist,
          'album': updatedSong.album,
          'duration': updatedSong.duration?.inMilliseconds,
          'file_path': updatedSong.filePath,
          'artwork_path': updatedSong.artworkPath,
          'artwork_uri': updatedSong.artworkUri,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'dominant_color': updatedSong.dominantColor,
        });
        print(
          '[MusicHistory] Updated metadata in DB for: ${updatedSong.title}',
        );
      } catch (e) {
        print('[MusicHistory] Error updating metadata in DB: $e');
      }
    }
  }
}
