import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_history_item.dart';

/// Servicio para gestionar el historial de descargas
class DownloadHistoryService {
  static const String _historyKey = 'download_history';
  static const int _maxHistoryItems = 100; // Límite de items en historial

  /// Agregar un item al historial
  static Future<void> addToHistory(DownloadHistoryItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await getHistory();

      // Evitar duplicados (por ID)
      history.removeWhere((h) => h.id == item.id);

      // Agregar al inicio
      history.insert(0, item);

      // Limitar el tamaño del historial
      if (history.length > _maxHistoryItems) {
        history.removeRange(_maxHistoryItems, history.length);
      }

      // Guardar
      final jsonList = history.map((h) => h.toJson()).toList();
      await prefs.setString(_historyKey, jsonEncode(jsonList));
    } catch (e) {
      print('[DownloadHistoryService] Error adding to history: $e');
    }
  }

  /// Obtener todo el historial
  static Future<List<DownloadHistoryItem>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_historyKey);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList
          .map(
            (json) =>
                DownloadHistoryItem.fromJson(json as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      print('[DownloadHistoryService] Error getting history: $e');
      return [];
    }
  }

  /// Eliminar un item del historial
  static Future<void> removeFromHistory(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await getHistory();

      history.removeWhere((h) => h.id == id);

      final jsonList = history.map((h) => h.toJson()).toList();
      await prefs.setString(_historyKey, jsonEncode(jsonList));
    } catch (e) {
      print('[DownloadHistoryService] Error removing from history: $e');
    }
  }

  /// Limpiar todo el historial
  static Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (e) {
      print('[DownloadHistoryService] Error clearing history: $e');
    }
  }

  /// Buscar en el historial
  static Future<List<DownloadHistoryItem>> searchHistory(String query) async {
    try {
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
