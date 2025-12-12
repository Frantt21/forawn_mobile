// lib/screens/translate_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key});

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  final TextEditingController _inputController = TextEditingController();
  String _translation = '';
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  // Mapa de idiomas -> código de país para la API
  static const Map<String, String> _languages = {
    'Inglés': 'en',
    'Español': 'es',
    'Francés': 'fr',
    'Alemán': 'de',
    'Portugués': 'pt',
    'Italiano': 'it',
    'Chino': 'zh',
    'Japonés': 'ja',
    'Coreano': 'ko',
    'Ruso': 'ru',
  };

  String _targetLang = 'Inglés';

  @override
  void dispose() {
    _debounce?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (text.trim().isEmpty) {
      setState(() {
        _translation = '';
        _error = null;
        _loading = false;
      });
      return;
    }

    // Esperar 800ms antes de traducir
    _debounce = Timer(const Duration(milliseconds: 800), _translate);
  }

  Future<void> _translate() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final targetCode = _languages[_targetLang] ?? 'en';
      final url = Uri.parse(ApiConfig.getTranslationUrl(text, targetCode));

      final resp = await http.get(url).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final body = resp.body;
        try {
          final decoded = json.decode(body);
          String? translated;

          if (decoded is Map) {
            if (decoded.containsKey('translation')) {
              translated = decoded['translation']?.toString();
            } else if (decoded.containsKey('result')) {
              translated = decoded['result']?.toString();
            } else if (decoded.containsKey('data')) {
              final data = decoded['data'];
              if (data is Map && data.containsKey('translation')) {
                translated = data['translation']?.toString();
              } else {
                translated = data.toString();
              }
            }
          }

          translated ??= (decoded is String ? decoded : body);

          setState(() {
            _translation = translated!;
          });
        } catch (_) {
          setState(() {
            _translation = body.isNotEmpty ? body : 'Sin traducción disponible';
          });
        }
      } else {
        setState(() {
          _error = 'Error del servidor (${resp.statusCode})';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error de conexión';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    // Usamos greenAccent como color principal para esta pantalla
    const accentColor = Colors.greenAccent;
    const cardBackgroundColor = Color(0xFF1C1C1E); // Mismo color que en Home

    return Scaffold(
      appBar: AppBar(
        title: const Text('Traductor'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selector de Idioma Destino
              Card(
                color: cardBackgroundColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Traducir al:',
                        style: TextStyle(
                          color: textColor.withOpacity(0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _targetLang,
                          dropdownColor: cardBackgroundColor,
                          icon: const Icon(
                            Icons.arrow_drop_down,
                            color: accentColor,
                          ),
                          style: const TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          items: _languages.keys
                              .map(
                                (k) =>
                                    DropdownMenuItem(value: k, child: Text(k)),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _targetLang = v;
                            });
                            if (_inputController.text.isNotEmpty) {
                              _translate();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Área de Entrada (Input)
              Expanded(
                child: Card(
                  color: cardBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Escribe texto (Auto-detectar)',
                          style: TextStyle(
                            color: textColor.withOpacity(0.5),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            onChanged: _onTextChanged,
                            style: TextStyle(color: textColor, fontSize: 18),
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: accentColor,
                            decoration: InputDecoration(
                              hintText: 'Empieza a escribir...',
                              hintStyle: TextStyle(
                                color: textColor.withOpacity(0.3),
                              ),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Área de Salida (Output)
              Expanded(
                child: Card(
                  color: cardBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: accentColor.withOpacity(0.15),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.translate,
                              size: 18,
                              color: accentColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Traducción ($_targetLang)',
                              style: const TextStyle(
                                color: accentColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            if (_loading)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accentColor,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: SingleChildScrollView(
                            child: _error != null
                                ? Text(
                                    _error!,
                                    style: TextStyle(
                                      color: theme.colorScheme.error,
                                    ),
                                  )
                                : SelectableText(
                                    _translation.isEmpty && !_loading
                                        ? '...'
                                        : _translation,
                                    style: TextStyle(
                                      color: _translation.isEmpty
                                          ? textColor.withOpacity(0.3)
                                          : textColor,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    cursorColor: accentColor,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
