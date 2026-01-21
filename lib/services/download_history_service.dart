import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_history_item.dart';
import 'database_helper.dart';

/// Servicio para gestionar el historial de descargas
class DownloadHistoryService {
  static const String _historyKey = 'download_history';
  static const int _maxHistoryItems = 100; // Límite de items en historial

  /// Agregar un item al historial
  static Future<void> addToHistory(DownloadHistoryItem item) async {
    try {
      // Lazy migration check not strictly needed here if we just insert,
      // but strictly speaking we might want to migrate first to preserve order.
      // We'll trust getHistory() to handle migration if the user views the list.
      // But if we insert now and then migrate, this item plays well.

      // Insertar o reemplazar en SQLite
      await DatabaseHelper().addToDownloadHistory({
        'id': item.id,
        'video_id': item.downloadUrl, // Usamos downloadUrl como identificador
        'title': item.name,
        'artist': item.artists,
        'thumbnail_url': item.imageUrl,
        'file_path': '', // El modelo no tiene path, lo dejamos vacío
        'downloaded_at': item.downloadedAt.millisecondsSinceEpoch,
      });

      // Cleanup: Keep only last N items
      _enforceLimit();
    } catch (e) {
      print('[DownloadHistoryService] Error adding to history: $e');
    }
  }

  static Future<void> _enforceLimit() async {
    try {
      final dbHelper = DatabaseHelper();
      final allItems = await dbHelper.getDownloadHistory(
        limit: _maxHistoryItems + 20,
      ); // Get a bit more
      if (allItems.length > _maxHistoryItems) {
        // Identify items to remove (the ones after index 100)
        // getDownloadHistory returns ordered DESC (newest first).
        // so we delete items from index 100 onwards.
        for (int i = _maxHistoryItems; i < allItems.length; i++) {
          await dbHelper.deleteFromDownloadHistory(allItems[i]['id']);
        }
      }
    } catch (e) {
      print('[DownloadHistory] Error enforcing limit: $e');
    }
  }

  /// Obtener todo el historial
  static Future<List<DownloadHistoryItem>> getHistory() async {
    try {
      final dbHelper = DatabaseHelper();
      var historyMaps = await dbHelper.getDownloadHistory(
        limit: _maxHistoryItems,
      );

      // --- MIGRATION CHECK ---
      if (historyMaps.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.containsKey(_historyKey)) {
          await _migrateFromPrefs();
          historyMaps = await dbHelper.getDownloadHistory(
            limit: _maxHistoryItems,
          );
        }
      }
      // -----------------------

      return historyMaps
          .map(
            (map) => DownloadHistoryItem(
              id: map['id'],
              name: map['title'] ?? 'Unknown',
              artists: map['artist'] ?? 'Unknown Artist',
              imageUrl: map['thumbnail_url'],
              downloadUrl: map['video_id'] ?? '',
              downloadedAt: map['downloaded_at'] != null
                  ? DateTime.fromMillisecondsSinceEpoch(map['downloaded_at'])
                  : DateTime.now(),
              source: 'youtube', // Defecto ya que no lo guardamos en BD
              durationMs: null,
            ),
          )
          .toList();
    } catch (e) {
      print('[DownloadHistoryService] Error getting history: $e');
      return [];
    }
  }

  static Future<void> _migrateFromPrefs() async {
    print('[DownloadHistory] Migrating to SQLite...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_historyKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        final items = jsonList
            .map((j) => DownloadHistoryItem.fromJson(j))
            .toList();

        for (final item in items) {
          await DatabaseHelper().addToDownloadHistory({
            'id': item.id,
            'video_id': item.downloadUrl,
            'title': item.name,
            'artist': item.artists,
            'thumbnail_url': item.imageUrl,
            'file_path': '',
            'downloaded_at': item.downloadedAt.millisecondsSinceEpoch,
          });
        }
        await prefs.remove(_historyKey); // Clear after migration
      }
    } catch (e) {
      print('[DownloadHistory] Migration error: $e');
    }
  }

  /// Eliminar un item del historial
  static Future<void> removeFromHistory(String id) async {
    try {
      await DatabaseHelper().deleteFromDownloadHistory(id);
    } catch (e) {
      print('[DownloadHistoryService] Error removing from history: $e');
    }
  }

  /// Limpiar todo el historial
  static Future<void> clearHistory() async {
    try {
      await DatabaseHelper().clearDownloadHistory();
      // Clear prefs too just in case
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_historyKey)) {
        await prefs.remove(_historyKey);
      }
    } catch (e) {
      print('[DownloadHistoryService] Error clearing history: $e');
    }
  }

  /// Buscar en el historial
  static Future<List<DownloadHistoryItem>> searchHistory(String query) async {
    try {
      // In-memory filter is sufficient for < 100 items
      final history = await getHistory();
      final lowerQuery = query.toLowerCase();

      return history.where((item) {
        return item.name.toLowerCase().contains(lowerQuery) ||
            item.artists.toLowerCase().contains(lowerQuery);
      }).toList();
    } catch (e) {
      print('[DownloadHistoryService] Error searching history: $e');
      return [];
    }
  }
}
