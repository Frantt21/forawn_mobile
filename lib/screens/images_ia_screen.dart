// lib/screens/images_ia_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../services/image_service.dart';
import '../services/saf_helper.dart';
import '../services/permission_helper.dart';
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
  final List<GeneratedImage> _chatHistory = [];

  bool _isGenerating = false;
  // Map para trackear qué imagen se está descargando (si quisiéramos múltiples descargas)
  // Por ahora usaremos un estado simple global para la descarga activa o local al item si fuera widget complejo
  String? _downloadingUrl;
  double _downloadProgress = 0.0;

  // Timer? _debounce; // Ya no necesitamos debounce si hay botón de enviar explícito

  // Ratios disponibles
  final List<String> _ratios = ['1:1', '9:16', '16:9', '9:19', '3:4'];
  String _selectedRatio = '1:1';

  // SAF treeUri para esta screen
  String? _imagesTreeUri;
  static const _prefsKey = 'saf_tree_uri_images';

  @override
  void initState() {
    super.initState();
    _loadSavedTreeUri();
  }

  @override
  void dispose() {
    // _debounce?.cancel();
    _promptController.dispose();
    _scrollController.dispose();
    _imageService.dispose();
    super.dispose();
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

  Future<void> _generateImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Escribe una descripción para generar la imagen'),
        ),
      );
      return;
    }

    // Opcional: Ocultar teclado
    FocusScope.of(context).unfocus();

    setState(() {
      _isGenerating = true;
    });

    final url = await _imageService.generateImage(
      prompt: prompt,
      ratio: _selectedRatio,
    );

    if (url == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo generar la imagen')),
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

    // Scroll al final después de agregar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _downloadImage(String imageUrl) async {
    if (_downloadingUrl != null)
      return; // Evitar descargas paralelas por simplicidad

    final hasPerm = await _requestStoragePermission();
    if (!hasPerm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Se necesitan permisos de almacenamiento'),
        ),
      );
      return;
    }

    setState(() {
      _downloadingUrl = imageUrl;
      _downloadProgress = 0.0;
    });

    try {
      // 1) Descargar a temp
      final tempPath = await _imageService.downloadToTemp(imageUrl, (p) {
        safeSetState(() => _downloadProgress = p);
      });

      if (tempPath == null) {
        throw Exception('Error descargando imagen');
      }

      final fileName = p.basename(tempPath);

      // 2) Guardar usando SAF si hay treeUri
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
        // fallback: copiar a Download
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
          const SnackBar(
            content: Text('Imagen guardada correctamente'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[ImagesIA] downloadImage error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al guardar la imagen'),
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
                title: const Text(
                  'Descargar imagen',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _downloadImage(item.imageUrl);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white),
                title: const Text(
                  'Copiar prompt',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  // Implementar copia al portapapeles si se desea
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
    final theme = Theme.of(context);
    const accentColor = Colors.yellowAccent;
    const cardBackgroundColor = Color(0xFF0F0F10);
    const bubbleColor = Color(0xFF1C1C1E);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Generador IA'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              Icons.folder_open,
              color: _imagesTreeUri == null ? Colors.white : accentColor,
            ),
            tooltip: _imagesTreeUri == null
                ? 'Seleccionar carpeta'
                : 'Carpeta seleccionada',
            onPressed: () async {
              try {
                final picked = await SafHelper.pickDirectory();
                if (picked != null) {
                  await _saveTreeUri(picked);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Carpeta seleccionada')),
                    );
                  }
                }
              } catch (_) {}
            },
          ),
        ],
      ),
      // Extend body to allow content behind transparent status/nav bars if needed
      // but here we want input at bottom.
      body: Column(
        children: [
          // Chat Area
          Expanded(
            child: _chatHistory.isEmpty
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
                          'Inicia una conversación creativa',
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 20,
                    ),
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
                          alignment: Alignment
                              .centerRight, // O Left, dependiendo del estilo deseado
                          // Vamos a usar estilo chat: Prompt (user) a la derecha, Imagen (bot) a la izquierda?
                          // El usuario pidió "como si fuese un chat".
                          // Típicamente: Prompt Usuario -> Derecha. Imagen AI -> Izquierda.
                          // Vamos a hacerlo unificado en una burbuja por generación para simplificar la asociación.
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

          // Input Area Flotante
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF0F0F10), // Fondo scuro para el input area
              border: Border(top: BorderSide(color: Colors.white12)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 10,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Text Field Area con Ratio Integrado
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white10),
                    ),
                    padding: const EdgeInsets.only(
                      left: 16,
                      right: 8,
                      top: 4,
                      bottom: 4,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                          decoration: const InputDecoration(
                            hintText: 'Describe tu imagen...',
                            hintStyle: TextStyle(color: Colors.white38),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
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
                              tooltip: 'Generar',
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
