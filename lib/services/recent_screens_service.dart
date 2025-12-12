// lib/services/recent_screens_service.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecentScreensService {
  static final RecentScreensService _instance = RecentScreensService._internal();
  factory RecentScreensService() => _instance;
  RecentScreensService._internal();

  static const String _prefsKey = 'recent_screens_v1';
  final List<RecentScreen> _recentScreens = [];
  bool _initialized = false;

  List<RecentScreen> get recentScreens => List.unmodifiable(_recentScreens);

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _initialized = true;
        return;
      }

      // Intentamos decodificar; si falla, lo registramos y limpiamos
      dynamic decoded;
      try {
        decoded = json.decode(raw);
      } catch (e) {
        // JSON corrupto: log y limpiar
        print('[RecentScreensService] JSON decode failed, clearing stored data. raw=$raw');
        await prefs.remove(_prefsKey);
        _initialized = true;
        return;
      }

      if (decoded is! List) {
        // Formato inesperado: limpiar y salir
        print('[RecentScreensService] Unexpected stored format (not a List). raw=$raw');
        await prefs.remove(_prefsKey);
        _initialized = true;
        return;
      }

      _recentScreens.clear();
      for (final item in decoded) {
        try {
          if (item == null) {
            // ignorar nulos
            continue;
          }
          if (item is! Map) {
            // ignorar entradas que no sean mapas
            continue;
          }
          final map = Map<String, dynamic>.from(item);
          final screen = RecentScreen.fromJson(map);
          // Validación mínima: route no vacío
          if (screen.route.isNotEmpty) {
            _recentScreens.add(screen);
          }
        } catch (e) {
          // Ignorar entradas inválidas pero loguear para depuración
          print('[RecentScreensService] Ignoring invalid recent entry: $e; entry=$item');
        }
      }
    } catch (e) {
      print('[RecentScreensService] init error: $e');
    } finally {
      _initialized = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = json.encode(_recentScreens.map((s) => s.toJson()).toList());
      await prefs.setString(_prefsKey, encoded);
    } catch (e) {
      print('[RecentScreensService] persist error: $e');
    }
  }

  Future<void> addScreen(String title, String route, IconData icon, Color color) async {
    // defensivo: validar route
    if (route.trim().isEmpty) return;

    _recentScreens.removeWhere((screen) => screen.route == route);

    _recentScreens.insert(
      0,
      RecentScreen(
        title: title,
        route: route,
        iconCodePoint: icon.codePoint,
        iconFontFamily: icon.fontFamily,
        iconFontPackage: icon.fontPackage,
        colorValue: color.value,
        visitedAt: DateTime.now(),
      ),
    );

    if (_recentScreens.length > 10) {
      _recentScreens.removeLast();
    }

    await _persist();
  }

  Future<void> clearHistory() async {
    _recentScreens.clear();
    await _persist();
  }
}

class RecentScreen {
  final String title;
  final String route;
  final int iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final int colorValue;
  final DateTime visitedAt;

  RecentScreen({
    required this.title,
    required this.route,
    required this.iconCodePoint,
    required this.iconFontFamily,
    required this.iconFontPackage,
    required this.colorValue,
    required this.visitedAt,
  });

  IconData get icon => IconData(iconCodePoint, fontFamily: iconFontFamily, fontPackage: iconFontPackage);
  Color get color => Color(colorValue);

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'route': route,
      'iconCodePoint': iconCodePoint,
      'iconFontFamily': iconFontFamily,
      'iconFontPackage': iconFontPackage,
      'colorValue': colorValue,
      'visitedAt': visitedAt.toIso8601String(),
    };
  }

  factory RecentScreen.fromJson(Map<String, dynamic> json) {
    // Valores por defecto seguros
    final title = (json['title'] is String) ? json['title'] as String : '';
    final route = (json['route'] is String) ? json['route'] as String : '';
    final iconCodePoint = (json['iconCodePoint'] is int) ? json['iconCodePoint'] as int : 0;
    final iconFontFamily = json['iconFontFamily'] is String ? json['iconFontFamily'] as String : null;
    final iconFontPackage = json['iconFontPackage'] is String ? json['iconFontPackage'] as String : null;
    final colorValue = (json['colorValue'] is int) ? json['colorValue'] as int : 0xFF000000;
    final visitedAt = DateTime.tryParse(json['visitedAt']?.toString() ?? '') ?? DateTime.now();

    return RecentScreen(
      title: title,
      route: route,
      iconCodePoint: iconCodePoint,
      iconFontFamily: iconFontFamily,
      iconFontPackage: iconFontPackage,
      colorValue: colorValue,
      visitedAt: visitedAt,
    );
  }

  String get timeAgo {
    final difference = DateTime.now().difference(visitedAt);
    if (difference.inMinutes < 1) return 'Visitado ahora';
    if (difference.inMinutes < 60) return 'Visitado hace ${difference.inMinutes} min';
    if (difference.inHours < 24) return 'Visitado hace ${difference.inHours}h';
    if (difference.inDays == 1) return 'Visitado ayer';
    return 'Visitado hace ${difference.inDays}d';
  }
}
