// lib/services/database_helper.dart
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'forawn_metadata.db');

    return await openDatabase(
      path,
      version: 5,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Tabla de metadatos de canciones
    await db.execute('''
      CREATE TABLE songs_metadata (
        id TEXT PRIMARY KEY,
        title TEXT,
        artist TEXT,
        album TEXT,
        duration INTEGER,
        artwork_path TEXT,
        artwork_uri TEXT,
        file_path TEXT,
        dominant_color INTEGER,
        timestamp INTEGER
      )
    ''');

    // Tabla de caché de lyrics
    await db.execute('''
      CREATE TABLE lyrics_cache (
        id TEXT PRIMARY KEY,
        json_data TEXT,
        timestamp INTEGER
      )
    ''');

    // Tablas de Playlists y Favoritos (V3)
    await _createPlaylistTables(db);

    // Historiales (V5)
    await _createHistoryTables(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migración V1 -> V2: Agregar tabla lyrics_cache
      await db.execute('''
        CREATE TABLE lyrics_cache (
          id TEXT PRIMARY KEY,
          json_data TEXT,
          timestamp INTEGER
        )
      ''');
    }

    if (oldVersion < 3) {
      // Migración V2 -> V3: Agregar tablas de playlists y favoritos
      await _createPlaylistTables(db);
    }

    if (oldVersion < 4) {
      // Migración V3 -> V4: Agregar file_path a songs_metadata
      try {
        await db.execute(
          'ALTER TABLE songs_metadata ADD COLUMN file_path TEXT',
        );
      } catch (e) {
        print('Error adding file_path column: $e');
      }
    }

    if (oldVersion < 5) {
      // Migración V4 -> V5: Agregar tablas de historial
      await _createHistoryTables(db);
    }
  }

  Future<void> _createHistoryTables(Database db) async {
    // Historial de Reproducción
    // Solo guardamos song_id y fecha. La canción debe estar en songs_metadata
    await db.execute('''
      CREATE TABLE playback_history (
        song_id TEXT,
        played_at INTEGER,
        PRIMARY KEY (song_id) 
      )
    ''');
    // Nota: PK es song_id para evitar duplicados y solo actualizar el timestamp

    // Historial de Descargas
    await db.execute('''
      CREATE TABLE download_history (
        id TEXT PRIMARY KEY,
        video_id TEXT,
        title TEXT,
        artist TEXT,
        thumbnail_url TEXT,
        file_path TEXT,
        downloaded_at INTEGER
      )
    ''');
  }

  // ... (Existing CRUD methods for Metadata, Lyrics, Playlists, Favorites) ...

  // --- Playback History ---

  Future<void> addToPlaybackHistory(String songId) async {
    final db = await database;
    await db.insert('playback_history', {
      'song_id': songId,
      'played_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<String>> getPlaybackHistory({int limit = 50}) async {
    final db = await database;
    final results = await db.query(
      'playback_history',
      columns: ['song_id'],
      orderBy: 'played_at DESC',
      limit: limit,
    );
    return results.map((r) => r['song_id'] as String).toList();
  }

  Future<void> clearPlaybackHistory() async {
    final db = await database;
    await db.delete('playback_history');
  }

  // --- Download History ---

  Future<void> addToDownloadHistory(Map<String, dynamic> item) async {
    final db = await database;
    await db.insert(
      'download_history',
      item,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getDownloadHistory({
    int limit = 100,
  }) async {
    final db = await database;
    return await db.query(
      'download_history',
      orderBy: 'downloaded_at DESC',
      limit: limit,
    );
  }

  Future<void> deleteFromDownloadHistory(String id) async {
    final db = await database;
    await db.delete('download_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearDownloadHistory() async {
    final db = await database;
    await db.delete('download_history');
  }

  Future<void> _createPlaylistTables(Database db) async {
    // Tabla Playlists
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT,
        description TEXT,
        image_path TEXT,
        created_at INTEGER,
        last_opened INTEGER,
        is_pinned INTEGER DEFAULT 0
      )
    ''');

    // Tabla Playlist Songs (Relación M:N)
    await db.execute('''
      CREATE TABLE playlist_songs (
        playlist_id TEXT,
        song_id TEXT,
        added_at INTEGER,
        PRIMARY KEY (playlist_id, song_id)
      )
    ''');

    // Tabla Favoritos
    await db.execute('''
      CREATE TABLE favorites (
        song_id TEXT PRIMARY KEY,
        added_at INTEGER
      )
    ''');
  }

  // Métodos CRUD Metadatos

  /// Insertar o actualizar metadatos
  Future<void> insertMetadata(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert(
      'songs_metadata',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Obtener metadatos por ID
  Future<Map<String, dynamic>?> getMetadata(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'songs_metadata',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return maps.first;
    }
    return null;
  }

  /// Eliminar metadatos por ID
  Future<void> deleteMetadata(String id) async {
    final db = await database;
    await db.delete('songs_metadata', where: 'id = ?', whereArgs: [id]);
  }

  /// Limpiar toda la tabla de metadatos
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('songs_metadata');
  }

  // Métodos CRUD Lyrics

  /// Insertar o actualizar lyrics
  Future<void> insertLyrics(String id, String jsonData) async {
    final db = await database;
    await db.insert('lyrics_cache', {
      'id': id,
      'json_data': jsonData,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Obtener lyrics por ID
  Future<String?> getLyrics(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'lyrics_cache',
      columns: ['json_data'],
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return maps.first['json_data'] as String?;
    }
    return null;
  }

  /// Eliminar lyrics por ID
  Future<void> deleteLyrics(String id) async {
    final db = await database;
    await db.delete('lyrics_cache', where: 'id = ?', whereArgs: [id]);
  }

  /// Limpiar toda la tabla de lyrics
  Future<void> clearAllLyrics() async {
    final db = await database;
    await db.delete('lyrics_cache');
  }

  /// Contar lyrics en caché
  Future<int> countLyrics() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM lyrics_cache'),
        ) ??
        0;
  }

  // --- CRUD Playlists ---

  Future<void> insertPlaylist(Map<String, dynamic> playlist) async {
    final db = await database;
    await db.insert(
      'playlists',
      playlist,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updatePlaylist(Map<String, dynamic> playlist) async {
    final db = await database;
    await db.update(
      'playlists',
      playlist,
      where: 'id = ?',
      whereArgs: [playlist['id']],
    );
  }

  Future<List<Map<String, dynamic>>> getAllPlaylists() async {
    final db = await database;
    return await db.query('playlists');
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    // Eliminar playlist y sus canciones asociadas
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [id],
    );
  }

  // --- CRUD Playlist Songs ---

  Future<void> addSongToPlaylist(String playlistId, String songId) async {
    final db = await database;
    await db.insert(
      'playlist_songs',
      {
        'playlist_id': playlistId,
        'song_id': songId,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore, // Ignorar si ya existe
    );
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final db = await database;
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
    );
  }

  Future<List<String>> getPlaylistSongIds(String playlistId) async {
    final db = await database;
    final results = await db.query(
      'playlist_songs',
      columns: ['song_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'added_at ASC', // Ordenar por orden de adición
    );
    return results.map((r) => r['song_id'] as String).toList();
  }

  // --- CRUD Favorites ---

  Future<void> addToFavorites(String songId) async {
    final db = await database;
    await db.insert('favorites', {
      'song_id': songId,
      'added_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeFromFavorites(String songId) async {
    final db = await database;
    await db.delete('favorites', where: 'song_id = ?', whereArgs: [songId]);
  }

  Future<List<String>> getFavoriteSongIds() async {
    final db = await database;
    final results = await db.query(
      'favorites',
      columns: ['song_id'],
      orderBy: 'added_at DESC', // Más recientes primero
    );
    return results.map((r) => r['song_id'] as String).toList();
  }

  Future<bool> isFavorite(String songId) async {
    final db = await database;
    final results = await db.query(
      'favorites',
      where: 'song_id = ?',
      whereArgs: [songId],
    );
    return results.isNotEmpty;
  }
}
