import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import 'database_helper.dart';
import 'music_library_service.dart';

class PlaylistService extends ChangeNotifier {
  static final PlaylistService _instance = PlaylistService._internal();
  factory PlaylistService() => _instance;
  PlaylistService._internal();

  static const String _playlistsKey = 'user_playlists';
  static const String _favoritesKey = 'user_favorites';

  List<Playlist> _playlists = [];
  final Set<String> _likedSongIds = {};

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  Set<String> get likedSongIds => Set.unmodifiable(_likedSongIds);
  final ValueNotifier<List<String>> favoritesNotifier = ValueNotifier([]);

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) return;

    // Verificar si necesitamos migrar de SharedPreferences a SQLite
    await _checkAndMigrate();

    // Cargar datos desde SQLite
    await _loadData();

    // Escuchar actualizaciones de metadatos en segundo plano
    MusicLibraryService.onMetadataUpdated.addListener(_onMetadataUpdated);

    isInitialized = true;
  }

  void _onMetadataUpdated() async {
    final uri = MusicLibraryService.onMetadataUpdated.value;
    if (uri != null) {
      bool needNotify = false;
      final dbHelper = DatabaseHelper();

      // 1. Check Playlists
      for (int i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        final songIndex = playlist.songs.indexWhere((s) => s.filePath == uri);

        if (songIndex != -1) {
          // Found song in playlist, hydrate it
          final cacheKey = uri.hashCode.toString();
          final metadata = await dbHelper.getMetadata(cacheKey);

          if (metadata != null) {
            final currentSong = playlist.songs[songIndex];
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

            final updatedSongs = List<Song>.from(playlist.songs);
            updatedSongs[songIndex] = updatedSong;

            _playlists[i] = playlist.copyWith(songs: updatedSongs);
            needNotify = true;
          }
        }
      }

      if (needNotify) notifyListeners();
    }
  }

  /// Migración única de SharedPreferences a SQLite
  Future<void> _checkAndMigrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // OPTIMIZATION: Check explicit flag first to avoid DB queries
      if (prefs.getBool('playlist_db_migrated') == true) {
        return;
      }

      final dbHelper = DatabaseHelper();
      final existingPlaylists = await dbHelper.getAllPlaylists();
      final existingFavorites = await dbHelper.getFavoriteSongIds();

      // Si ya hay datos en SQLite, asumimos que se ha migrado o se usa SQLite
      if (existingPlaylists.isNotEmpty || existingFavorites.isNotEmpty) {
        await prefs.setBool('playlist_db_migrated', true);
        return;
      }

      print(
        '[PlaylistService] Starting migration from SharedPreferences to SQLite...',
      );

      // 1. Migrar Playlists
      final String? playlistsJson = prefs.getString(_playlistsKey);
      if (playlistsJson != null) {
        final List<dynamic> decoded = json.decode(playlistsJson);
        final oldPlaylists = decoded
            .map((item) => Playlist.fromJson(item))
            .toList();

        for (final playlist in oldPlaylists) {
          // Insertar Playlist
          await dbHelper.insertPlaylist({
            'id': playlist.id,
            'name': playlist.name,
            'description': playlist.description,
            'image_path': playlist.imagePath,
            'created_at': playlist.createdAt.millisecondsSinceEpoch,
            'last_opened': playlist.lastOpened?.millisecondsSinceEpoch,
            'is_pinned': playlist.isPinned ? 1 : 0,
          });

          // Insertar Canciones
          for (final song in playlist.songs) {
            // Asegurar que la canción existe en songs_metadata con su path
            await dbHelper.insertMetadata({
              'id': song.id,
              'title': song.title,
              'artist': song.artist,
              'album': song.album,
              'duration': song.duration?.inMilliseconds,
              'file_path': song.filePath,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            });

            // Relacionar canción con playlist
            await dbHelper.addSongToPlaylist(playlist.id, song.id);
          }
        }
        print('[PlaylistService] Migrated ${oldPlaylists.length} playlists');
      }

      // 2. Migrar Favoritos
      // Nota: Favoritos en prefs eran solo IDs. No tenemos el objeto Song completo aquí.
      // Solo podemos migrar los IDs. Si la canción no está en metadata, no se podrá reproducir
      // hasta que se escanee.
      final List<String>? favoritesList = prefs.getStringList(_favoritesKey);
      if (favoritesList != null) {
        for (final songId in favoritesList) {
          await dbHelper.addToFavorites(songId);
        }
        print('[PlaylistService] Migrated ${favoritesList.length} favorites');
      }

      // Mark as migrated successfully
      await prefs.setBool('playlist_db_migrated', true);
    } catch (e) {
      print('[PlaylistService] Error during migration: $e');
    }
  }

  Future<void> _loadData() async {
    final dbHelper = DatabaseHelper();

    // 1. Cargar Playlists (Solo estructura básica)
    final playlistsData = await dbHelper.getAllPlaylists();
    final loadedPlaylists = <Playlist>[];

    for (var p in playlistsData) {
      // Cargar canciones de cada playlist
      final songIds = await dbHelper.getPlaylistSongIds(p['id']);
      final songs = await _hydrateSongs(songIds);

      loadedPlaylists.add(
        Playlist(
          id: p['id'],
          name: p['name'],
          description: p['description'],
          imagePath: p['image_path'],
          createdAt: DateTime.fromMillisecondsSinceEpoch(p['created_at']),
          lastOpened: p['last_opened'] != null
              ? DateTime.fromMillisecondsSinceEpoch(p['last_opened'])
              : null,
          isPinned: p['is_pinned'] == 1,
          songs: songs,
        ),
      );
    }

    _playlists = loadedPlaylists;
    _sortPlaylists();

    // 2. Cargar Favoritos
    final favoriteIds = await dbHelper.getFavoriteSongIds();
    _likedSongIds.clear();
    _likedSongIds.addAll(favoriteIds);
    favoritesNotifier.value = List.from(_likedSongIds);

    notifyListeners();
  }

  /// Reconstruye objetos Song a partir de IDs usando la tabla songs_metadata
  Future<List<Song>> _hydrateSongs(List<String> songIds) async {
    final List<Song> songs = [];
    final dbHelper = DatabaseHelper();

    for (final id in songIds) {
      final metadata = await dbHelper.getMetadata(id);
      if (metadata != null && metadata['file_path'] != null) {
        // Reconstruimos la canción
        songs.add(
          Song(
            id: metadata['id'],
            title: metadata['title'] ?? 'Unknown',
            artist: metadata['artist'] ?? 'Unknown Artist',
            album: metadata['album'],
            duration: metadata['duration'] != null
                ? Duration(milliseconds: metadata['duration'])
                : null,
            filePath: metadata['file_path'], // CRÍTICO: Debe existir
            artworkPath: metadata['artwork_path'],
            artworkUri: metadata['artwork_uri'],
            dominantColor: metadata['dominant_color'],
          ),
        );
      }
    }
    return songs;
  }

  void _sortPlaylists() {
    _playlists.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;

      final aTime = a.lastOpened ?? a.createdAt;
      final bTime = b.lastOpened ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
  }

  // --- Favorites ---

  bool isLiked(String songId) => _likedSongIds.contains(songId);

  Future<void> toggleLike(String songId) async {
    final dbHelper = DatabaseHelper();
    if (_likedSongIds.contains(songId)) {
      _likedSongIds.remove(songId);
      await dbHelper.removeFromFavorites(songId);
    } else {
      _likedSongIds.add(songId);
      await dbHelper.addToFavorites(songId);
    }
    favoritesNotifier.value = List.from(_likedSongIds);
    notifyListeners();
  }

  // --- Playlists ---

  Future<void> logPlaylistOpen(String playlistId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final updatedPlaylist = _playlists[index].copyWith(
        lastOpened: DateTime.now(),
      );
      _playlists[index] = updatedPlaylist;
      _sortPlaylists();
      notifyListeners();

      // Update DB
      await DatabaseHelper().updatePlaylist({
        'id': playlistId,
        'last_opened': updatedPlaylist.lastOpened?.millisecondsSinceEpoch,
      });
    }
  }

  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    String? imagePath,
  }) async {
    final newPlaylist = Playlist(
      id: const Uuid().v4(),
      name: name,
      description: description,
      imagePath: imagePath,
      createdAt: DateTime.now(),
      lastOpened: DateTime.now(),
      songs: [],
    );

    _playlists.add(newPlaylist);
    _sortPlaylists();
    notifyListeners();

    // Save to DB
    await DatabaseHelper().insertPlaylist({
      'id': newPlaylist.id,
      'name': newPlaylist.name,
      'description': newPlaylist.description,
      'image_path': newPlaylist.imagePath,
      'created_at': newPlaylist.createdAt.millisecondsSinceEpoch,
      'last_opened': newPlaylist.lastOpened!.millisecondsSinceEpoch,
      'is_pinned': 0,
    });

    return newPlaylist;
  }

  Future<void> deletePlaylist(String playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    notifyListeners();
    await DatabaseHelper().deletePlaylist(playlistId);
  }

  Future<void> updatePlaylist(
    String id, {
    String? name,
    String? description,
    String? imagePath,
  }) async {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1) {
      final updated = _playlists[index].copyWith(
        name: name,
        description: description,
        imagePath: imagePath,
      );
      _playlists[index] = updated;
      notifyListeners();

      // Update DB fields
      await DatabaseHelper().updatePlaylist({
        'id': id,
        'name': name,
        'description': description,
        'image_path': imagePath,
      });
    }
  }

  Future<void> togglePin(String playlistId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final p = _playlists[index];
      final newStatus = !p.isPinned;
      _playlists[index] = p.copyWith(isPinned: newStatus);
      _sortPlaylists();
      notifyListeners();

      // Update DB
      await DatabaseHelper().updatePlaylist({
        'id': playlistId,
        'is_pinned': newStatus ? 1 : 0,
      });
    }
  }

  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      if (!playlist.songs.any((s) => s.id == song.id)) {
        final updatedSongs = List<Song>.from(playlist.songs)..add(song);

        final updatedPlaylist = playlist.copyWith(
          songs: updatedSongs,
          lastOpened: DateTime.now(),
        );

        _playlists[index] = updatedPlaylist;
        _sortPlaylists();
        notifyListeners();

        // 1. Guardar metadatos (incluyendo filePath) para asegurar persistencia
        await DatabaseHelper().insertMetadata({
          'id': song.id,
          'title': song.title,
          'artist': song.artist,
          'album': song.album,
          'duration': song.duration?.inMilliseconds,
          'file_path': song.filePath,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          // No sobrescribimos artwork path/uri aquí para no borrarlo si ya existe
          // Idealmente usaríamos un insert parcial o check existence
        });

        // 2. Relacionar
        await DatabaseHelper().addSongToPlaylist(playlistId, song.id);

        // 3. Actualizar last_opened playlist
        await DatabaseHelper().updatePlaylist({
          'id': playlistId,
          'last_opened': updatedPlaylist.lastOpened?.millisecondsSinceEpoch,
        });
      }
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      final updatedSongs = List<Song>.from(playlist.songs)
        ..removeWhere((s) => s.id == songId);

      if (updatedSongs.length != playlist.songs.length) {
        _playlists[index] = playlist.copyWith(songs: updatedSongs);
        notifyListeners();

        await DatabaseHelper().removeSongFromPlaylist(playlistId, songId);
      }
    }
  }
}
