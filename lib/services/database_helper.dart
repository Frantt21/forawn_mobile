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

    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE songs_metadata (
        id TEXT PRIMARY KEY,
        title TEXT,
        artist TEXT,
        album TEXT,
        duration INTEGER,
        artwork_path TEXT,
        artwork_uri TEXT,
        dominant_color INTEGER,
        timestamp INTEGER
      )
    ''');
  }

  // Métodos CRUD

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

  /// Limpiar toda la tabla
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('songs_metadata');
  }
}
