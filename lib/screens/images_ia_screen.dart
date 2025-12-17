// lib/screens/images_ia_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../services/image_service.dart';
import '../services/saf_helper.dart';
import '../services/permission_helper.dart';
import '../services/language_service.dart';
import '../utils/safe_http_mixin.dart';

class GeneratedImage {
  final String prompt;
  final String imageUrl;
  final String ratio;
  final DateTime timestamp;

  GeneratedImage({
    required this.prompt,
    required this.imageUrl,
    required this.ratio,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'prompt': prompt,
      'imageUrl': imageUrl,
      'ratio': ratio,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory GeneratedImage.fromJson(Map<String, dynamic> json) {
    return GeneratedImage(
      prompt: json['prompt'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      ratio: json['ratio'] ?? '1:1',
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
    );
  }
}

class ImagesIAScreen extends StatefulWidget {
  const ImagesIAScreen({super.key});

  @override
  State<ImagesIAScreen> createState() => _ImagesIAScreenState();
}

class _ImagesIAScreenState extends State<ImagesIAScreen> with SafeHttpMixin {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImageService _imageService = ImageService();

  // Historial de chat
  List<GeneratedImage> _chatHistory = [];

  bool _isGenerating = false;
  String? _downloadingUrl;
  double _downloadProgress = 0.0;

  // Ratios disponibles
  final List<String> _ratios = ['1:1', '9:16', '16:9', '9:19', '3:4'];
  String _selectedRatio = '1:1';

  // SAF treeUri para esta screen
  String? _imagesTreeUri;
  static const _prefsKey = 'saf_tree_uri_images';
  static const _historyKey = 'images_ia_history';

  @override
  void initState() {
    super.initState();
    _loadSavedTreeUri();
    _loadHistory();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _scrollController.dispose();
    _imageService.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? historyJson = prefs.getString(_historyKey);
      if (historyJson != null) {
        final List<dynamic> decoded = jsonDecode(historyJson);
        setState(() {
          _chatHistory = decoded
              .map((e) => GeneratedImage.fromJson(e))
              .toList();
        });
        // Scroll al final al cargar
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (e) {
      print('[ImagesIA] Error loading history: $e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(
        _chatHistory.map((e) => e.toJson()).toList(),
      );
      await prefs.setString(_historyKey, encoded);
    } catch (e) {
      print('[ImagesIA] Error saving history: $e');
    }
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LanguageService().getText('clear_history_images')),
        content: Text(
          LanguageService().getText('clear_history_images_confirm'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(LanguageService().getText('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(LanguageService().getText('delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _chatHistory.clear();
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    }
  }

  Future<void> _loadSavedTreeUri() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = prefs.getString(_prefsKey);
      if (uri != null && uri.isNotEmpty) {
        setState(() => _imagesTreeUri = uri);
      }
    } catch (e) {
      print('[ImagesIA] loadSavedTreeUri error: $e');
    }
  }

  Future<void> _saveTreeUri(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, uri);
      setState(() => _imagesTreeUri = uri);
    } catch (e) {
      print('[ImagesIA] saveTreeUri error: $e');
    }
  }

  Future<bool> _requestStoragePermission() async {
    return await PermissionHelper.requestStoragePermission();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _generateImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LanguageService().getText('enter_description'))),
      );
      return;
    }

    // Opcional: Ocultar teclado
    FocusScope.of(context).unfocus();

    setState(() {
      _isGenerating = true;
    });

    // Scroll inmediatamente al final para ver el loader (aunque el loader se añade en chatHistory + 1)
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final url = await _imageService.generateImage(
      prompt: prompt,
      ratio: _selectedRatio,
    );

    if (url == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('image_generation_error')),
          ),
        );
      }
      safeSetState(() => _isGenerating = false);
      return;
    }

    // Agregar al historial
    final newItem = GeneratedImage(
      prompt: prompt,
      imageUrl: url,
      ratio: _selectedRatio,
      timestamp: DateTime.now(),
    );

    safeSetState(() {
      _chatHistory.add(newItem);
      _isGenerating = false;
      _promptController.clear();
    });

    _saveHistory(); // Guardar

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _downloadImage(String imageUrl) async {
    if (_downloadingUrl != null) return;

    final hasPerm = await _requestStoragePermission();
    if (!hasPerm) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LanguageService().getText('storage_permission_needed')),
        ),
      );
      return;
    }

    setState(() {
      _downloadingUrl = imageUrl;
      _downloadProgress = 0.0;
    });

    try {
      final tempPath = await _imageService.downloadToTemp(imageUrl, (p) {
        safeSetState(() => _downloadProgress = p);
      });

      if (tempPath == null) {
        throw Exception('Error descargando imagen');
      }

      final fileName = p.basename(tempPath);

      if (_imagesTreeUri != null && _imagesTreeUri!.isNotEmpty) {
        final savedUri = await SafHelper.saveFileFromPath(
          treeUri: _imagesTreeUri!,
          tempPath: tempPath,
          fileName: fileName,
        );
        if (savedUri == null) {
          throw Exception('No se pudo guardar en la carpeta seleccionada');
        }
      } else {
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          try {
            await downloadsDir.create(recursive: true);
          } catch (_) {}
        }
        final destPath = '${downloadsDir.path}/$fileName';
        await File(tempPath).copy(destPath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('image_saved')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[ImagesIA] downloadImage error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('image_save_error')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        safeSetState(() {
          _downloadingUrl = null;
          _downloadProgress = 0.0;
        });
      }
    }
  }

  void _showImageOptions(GeneratedImage item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.download, color: Colors.white),
                title: Text(
                  LanguageService().getText('download_image'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _downloadImage(item.imageUrl);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white),
                title: Text(
                  LanguageService().getText('copy_prompt'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  _promptController.text = item.prompt;
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Colors.yellowAccent;
    const bubbleColor = Color(0xFF1C1C1E);

    return Scaffold(
      appBar: AppBar(
        title: Text(LanguageService().getText('ai_generator')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: LanguageService().getText('clear_history_images'),
            onPressed: _chatHistory.isEmpty ? null : _clearHistory,
          ),
          IconButton(
            icon: Icon(
              Icons.folder_open,
              color: _imagesTreeUri == null ? Colors.white : accentColor,
            ),
            tooltip: _imagesTreeUri == null
                ? LanguageService().getText('select_folder')
                : LanguageService().getText('folder_selected_tooltip'),
            onPressed: () async {
              try {
                final picked = await SafHelper.pickDirectory();
                if (picked != null) {
                  await _saveTreeUri(picked);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          LanguageService().getText('folder_selected'),
                        ),
                      ),
                    );
                  }
                }
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Chat List
          Positioned.fill(
            child: _chatHistory.isEmpty && !_isGenerating
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.white.withOpacity(0.1),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          LanguageService().getText(
                            'start_creative_conversation',
                          ),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    // Padding extra abajo para que el input flotante no tape el contenido
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
                    itemCount: _chatHistory.length + (_isGenerating ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _chatHistory.length) {
                        // Loading indicator bubble
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 20),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: bubbleColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accentColor,
                              ),
                            ),
                          ),
                        );
                      }

                      final item = _chatHistory[index];
                      return GestureDetector(
                        onLongPress: () => _showImageOptions(item),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // Prompt (User bubble)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: accentColor.withOpacity(0.2),
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(20),
                                      topRight: Radius.circular(20),
                                      bottomLeft: Radius.circular(20),
                                      bottomRight: Radius.circular(4),
                                    ),
                                  ),
                                  child: Text(
                                    item.prompt,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Image (AI response visual)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      constraints: const BoxConstraints(
                                        maxWidth: 300,
                                        maxHeight: 400,
                                      ),
                                      color: bubbleColor,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Image.network(
                                            item.imageUrl,
                                            fit: BoxFit.contain,
                                            loadingBuilder: (ctx, child, loadingProgress) {
                                              if (loadingProgress == null)
                                                return child;
                                              return Container(
                                                height: 200,
                                                width: 200,
                                                alignment: Alignment.center,
                                                child: CircularProgressIndicator(
                                                  color: accentColor,
                                                  value:
                                                      loadingProgress
                                                              .expectedTotalBytes !=
                                                          null
                                                      ? loadingProgress
                                                                .cumulativeBytesLoaded /
                                                            loadingProgress
                                                                .expectedTotalBytes!
                                                      : null,
                                                ),
                                              );
                                            },
                                          ),
                                          if (_downloadingUrl == item.imageUrl)
                                            Container(
                                              color: Colors.black54,
                                              child: Center(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const CircularProgressIndicator(
                                                      color: Colors.white,
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Text(
                                                      '${(_downloadProgress * 100).toInt()}%',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
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
                    },
                  ),
          ),

          // Input Flotante
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 8,
                  top: 4,
                  bottom: 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Campo de texto
                    TextField(
                      controller: _promptController,
                      // Cuando envía desde teclado también debería generar
                      onSubmitted: (_) =>
                          _isGenerating ? null : _generateImage(),
                      maxLines: null,
                      minLines: 1,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: LanguageService().getText('describe_image'),
                        hintStyle: const TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                        isDense: true,
                      ),
                    ),

                    // Fila inferior: Ratio selector (Izquierda) + Send Button (Derecha)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Selector de Ratio integrado
                        Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedRatio,
                              dropdownColor: const Color(0xFF2C2C2E),
                              icon: const Icon(
                                Icons.keyboard_arrow_down,
                                size: 16,
                                color: Colors.white60,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              onChanged: (val) {
                                if (val != null)
                                  setState(() => _selectedRatio = val);
                              },
                              items: _ratios.map((r) {
                                return DropdownMenuItem(
                                  value: r,
                                  child: Text(r),
                                );
                              }).toList(),
                            ),
                          ),
                        ),

                        // Botón de enviar
                        IconButton(
                          onPressed: _isGenerating ? null : _generateImage,
                          icon: _isGenerating
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: accentColor,
                                  ),
                                )
                              : const Icon(
                                  Icons.arrow_upward,
                                  color: accentColor,
                                ),
                          tooltip: LanguageService().getText('generate'),
                          style: IconButton.styleFrom(
                            backgroundColor: _isGenerating
                                ? Colors.transparent
                                : Colors.white10,
                            shape: const CircleBorder(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
