import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Modelo para una notificación de descarga
class DownloadNotification {
  final String id;
  final String title;
  final String message;
  final DateTime timestamp;
  final NotificationType type;

  DownloadNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    required this.type,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'type': type.index,
    };
  }

  factory DownloadNotification.fromJson(Map<String, dynamic> json) {
    return DownloadNotification(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      message: json['message'] ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      type: NotificationType.values[json['type'] ?? 0],
    );
  }
}

enum NotificationType {
  info, // Descarga iniciada
  success, // Descarga completada
  error, // Error en descarga
}

/// Servicio para gestionar el historial de notificaciones
class NotificationHistoryService {
  static const String _key = 'notification_history';
  static const int _maxNotifications = 50;

  /// Agregar una notificación al historial
  static Future<void> addNotification(DownloadNotification notification) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await getHistory();

      // Agregar al inicio
      history.insert(0, notification);

      // Mantener solo las últimas _maxNotifications
      if (history.length > _maxNotifications) {
        history.removeRange(_maxNotifications, history.length);
      }

      // Guardar usando JSON
      final jsonList = history.map((n) => n.toJson()).toList();
      await prefs.setString(_key, json.encode(jsonList));
    } catch (e) {
      print('[NotificationHistoryService] Error adding notification: $e');
    }
  }

  /// Obtener el historial de notificaciones
  static Future<List<DownloadNotification>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_key);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final List<dynamic> jsonList = json.decode(jsonString);
      return jsonList
          .map(
            (item) =>
                DownloadNotification.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } catch (e) {
      print('[NotificationHistoryService] Error getting history: $e');
      return [];
    }
  }

  /// Limpiar todo el historial
  static Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      print('[NotificationHistoryService] Error clearing history: $e');
    }
  }

  /// Eliminar una notificación específica
  static Future<void> removeNotification(String id) async {
    try {
      final history = await getHistory();
      history.removeWhere((n) => n.id == id);

      final prefs = await SharedPreferences.getInstance();
      final jsonList = history.map((n) => n.toJson()).toList();
      await prefs.setString(_key, json.encode(jsonList));
    } catch (e) {
      print('[NotificationHistoryService] Error removing notification: $e');
    }
  }
}
