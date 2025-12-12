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

class ImagesIAScreen extends StatefulWidget {
  const ImagesIAScreen({super.key});

  @override
  State<ImagesIAScreen> createState() => _ImagesIAScreenState();
}

class _ImagesIAScreenState extends State<ImagesIAScreen> with SafeHttpMixin {
  final TextEditingController _promptController = TextEditingController();
  final ImageService _imageService = ImageService();

  String? _imageUrl;
  bool _isGenerating = false;
  bool _isDownloading = false;
  double _progress = 0.0;
  Timer? _debounce;

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
    _debounce?.cancel();
    _promptController.dispose();
    _imageService.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (text.trim().isEmpty) return;

    // Esperar 1500ms antes de generar automáticamente
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      if (!_isGenerating) {
        _generateImage();
      }
    });
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

  Future<void> _pickFolder() async {
    try {
      final picked = await SafHelper.pickDirectory();
      if (picked != null) {
        await _saveTreeUri(picked);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Carpeta seleccionada correctamente')),
          );
        }
      }
    } catch (e) {
      print('[ImagesIA] pickFolder error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo seleccionar la carpeta')),
        );
      }
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

    setState(() {
      _isGenerating = true;
      _imageUrl = null;
      _progress = 0.0;
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

    safeSetState(() {
      _imageUrl = url;
      _isGenerating = false;
    });
  }

  Future<void> _downloadImage() async {
    if (_imageUrl == null) return;

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
      _isDownloading = true;
      _progress = 0.0;
    });

    try {
      // 1) Descargar a temp
      final tempPath = await _imageService.downloadToTemp(_imageUrl!, (p) {
        safeSetState(() => _progress = p);
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
          SnackBar(
            content: Text('Imagen guardada: $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, st) {
      print('[ImagesIA] downloadImage error: $e');
      print(st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al guardar la imagen'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      safeSetState(() {
        _isDownloading = false;
        _progress = 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    const accentColor = Colors.yellowAccent;
    const cardBackgroundColor = Color(0xFF0F0F10);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Images IA'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: () async {
                try {
                  final picked = await SafHelper.pickDirectory();
                  if (picked != null) {
                    await _saveTreeUri(picked);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Carpeta seleccionada correctamente'),
                        ),
                      );
                    }
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo seleccionar la carpeta'),
                      ),
                    );
                  }
                }
              },
              onLongPress: () {
                final msg = _imagesTreeUri ?? 'No hay carpeta seleccionada';
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(msg),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              },
              child: Tooltip(
                message: _imagesTreeUri == null
                    ? 'Seleccionar carpeta'
                    : 'Carpeta seleccionada',
                child: Icon(
                  Icons.folder_open,
                  color: _imagesTreeUri == null
                      ? Theme.of(context).appBarTheme.iconTheme?.color ??
                            Colors.white
                      : accentColor,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Prompt Input
              Card(
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
                        'Describe tu imagen',
                        style: TextStyle(
                          color: textColor.withOpacity(0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _promptController,
                        onChanged: _onTextChanged,
                        style: TextStyle(color: textColor, fontSize: 16),
                        maxLines: 4,
                        cursorColor: accentColor,
                        decoration: InputDecoration(
                          hintText:
                              'Ej: Un gato espacial flotando en el universo...',
                          hintStyle: TextStyle(
                            color: textColor.withOpacity(0.3),
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Ratio Selector + Generate Button Container
              Card(
                color: cardBackgroundColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Ratio:',
                        style: TextStyle(
                          color: textColor.withOpacity(0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedRatio,
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
                            items: _ratios
                                .map(
                                  (r) => DropdownMenuItem(
                                    value: r,
                                    child: Text(r),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(
                              () => _selectedRatio = v ?? _selectedRatio,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor:
                              Colors.black, // Texto negro para contraste
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onPressed: _isGenerating ? null : _generateImage,
                        icon: _isGenerating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.auto_awesome, size: 20),
                        label: Text(
                          _isGenerating ? 'Generando...' : 'Generar',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Image Preview
              Expanded(
                child: _imageUrl == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.image_outlined,
                              size: 64,
                              color: textColor.withOpacity(0.2),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'La imagen generada aparecerá aquí',
                              style: TextStyle(
                                color: textColor.withOpacity(0.4),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        children: [
                          Expanded(
                            child: Card(
                              color: cardBackgroundColor,
                              clipBehavior: Clip.antiAlias,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: accentColor.withOpacity(0.15),
                                  width: 1,
                                ),
                              ),
                              child: SizedBox(
                                width: double.infinity,
                                child: Image.network(
                                  _imageUrl!,
                                  fit: BoxFit.contain,
                                  loadingBuilder:
                                      (context, child, loadingProgress) {
                                        if (loadingProgress == null) {
                                          return child;
                                        }
                                        final prog =
                                            loadingProgress
                                                    .expectedTotalBytes !=
                                                null
                                            ? (loadingProgress
                                                      .cumulativeBytesLoaded /
                                                  (loadingProgress
                                                          .expectedTotalBytes ??
                                                      1))
                                            : null;
                                        return Center(
                                          child: CircularProgressIndicator(
                                            value: prog,
                                            color: accentColor,
                                          ),
                                        );
                                      },
                                  errorBuilder: (context, error, st) {
                                    return Center(
                                      child: Text(
                                        'Error al cargar la imagen',
                                        style: TextStyle(
                                          color: textColor.withOpacity(0.6),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accentColor,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: _isDownloading ? null : _downloadImage,
                              icon: _isDownloading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Icon(Icons.download),
                              label: Text(
                                _isDownloading
                                    ? 'Guardando...'
                                    : 'Descargar Imagen',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          if (_isDownloading) ...[
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: _progress,
                              color: accentColor,
                              backgroundColor: accentColor.withOpacity(0.2),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
