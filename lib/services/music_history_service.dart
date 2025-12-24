import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/music_metadata_cache.dart';

class MusicHistoryService {
  static final MusicHistoryService _instance = MusicHistoryService._internal();
  factory MusicHistoryService() => _instance;
  MusicHistoryService._internal();

  static const String _key = 'music_history';
  // Limitar historial (ej. 50, aunque mostremos solo 6 en el grid)
  static const int _maxHistory = 50;

  List<Song> _history = [];

  List<Song> get history => List.unmodifiable(_history);

  Future<void> init() async {
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString(_key);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        var loadedSongs = jsonList
            .map((json) => Song.fromJson(json))
            .where((song) => song.filePath.isNotEmpty) // Validar
            .toList();

        // Rehidratar metadatos desde caché (para recuperar artwork)
        final hydrationFutures = loadedSongs.map((song) async {
          try {
            final cached = await MusicMetadataCache.get(song.id);
            if (cached != null) {
              return song.copyWith(
                title: cached.title ?? song.title,
                artist: cached.artist ?? song.artist,
                artworkData: cached.artwork ?? song.artworkData,
              );
            }
          } catch (e) {
            print('[MusicHistory] Error rehydrating song ${song.id}: $e');
          }
          return song;
        });

        _history = await Future.wait(hydrationFutures);
      }
    } catch (e) {
      print('[MusicHistory] Error loading history: $e');
    }
  }

  Future<void> addToHistory(Song song) async {
    // Remover si ya existe para moverlo al principio (más reciente)
    _history.removeWhere((s) => s.filePath == song.filePath);

    // Insertar al inicio
    _history.insert(0, song);

    // Mantener límite
    if (_history.length > _maxHistory) {
      _history = _history.sublist(0, _maxHistory);
    }

    await _saveHistory();
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String jsonString = json.encode(
        _history.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_key, jsonString);
    } catch (e) {
      print('[MusicHistory] Error saving history: $e');
    }
  }

  Future<void> clearHistory() async {
    _history.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
