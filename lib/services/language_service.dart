import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageService extends ChangeNotifier {
  static final LanguageService _instance = LanguageService._internal();
  factory LanguageService() => _instance;
  LanguageService._internal();

  Map<String, String> _localizedStrings = {};
  String _currentLanguage = 'en'; // Default language

  String get currentLanguage => _currentLanguage;

  /// Initialize the language service
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _currentLanguage = prefs.getString('language') ?? 'en';
    await _loadLanguage(_currentLanguage);
    notifyListeners();
  }

  /// Load language from JSON file
  Future<void> _loadLanguage(String languageCode) async {
    try {
      final String jsonString = await rootBundle.loadString(
        'assets/languages/$languageCode.json',
      );
      final Map<String, dynamic> jsonMap = json.decode(jsonString);
      _localizedStrings = jsonMap.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    } catch (e) {
      debugPrint('Error loading language $languageCode: $e');
      // Fallback to English if loading fails
      if (languageCode != 'en') {
        await _loadLanguage('en');
      }
    }
  }

  /// Change the current language
  Future<void> changeLanguage(String languageCode) async {
    if (_currentLanguage == languageCode) return;

    _currentLanguage = languageCode;
    await _loadLanguage(languageCode);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', languageCode);

    notifyListeners();
  }

  /// Get translated string by key
  String getText(String key, [Map<String, String>? variables]) {
    String text = _localizedStrings[key] ?? key;

    // Replace variables if provided
    if (variables != null) {
      variables.forEach((varKey, varValue) {
        text = text.replaceAll('{{$varKey}}', varValue);
      });
    }

    return text;
  }

  /// Get available languages
  static const List<Map<String, String>> availableLanguages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'es', 'name': 'Español'},
  ];
}

/// Extension to make it easier to access translations
extension LanguageExtension on BuildContext {
  String getText(String key) {
    return LanguageService().getText(key);
  }
}
