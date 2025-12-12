// lib/screens/qr_generator_screen.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/saf_helper.dart';
import '../services/permission_helper.dart';

class QRGeneratorScreen extends StatefulWidget {
  const QRGeneratorScreen({super.key});

  @override
  State<QRGeneratorScreen> createState() => _QRGeneratorScreenState();
}

class _QRGeneratorScreenState extends State<QRGeneratorScreen> {
  final TextEditingController _textController = TextEditingController();
  final GlobalKey _qrKey = GlobalKey();
  String _qrData = '';
  bool _isSaving = false;

  // SAF treeUri para esta screen
  String? _qrTreeUri;
  static const _prefsKey = 'saf_tree_uri_qr';

  @override
  void initState() {
    super.initState();
    _loadSavedTreeUri();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedTreeUri() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = prefs.getString(_prefsKey);
      if (uri != null && uri.isNotEmpty) {
        setState(() => _qrTreeUri = uri);
      }
    } catch (e) {
      print('[QRGenerator] loadSavedTreeUri error: $e');
    }
  }

  Future<void> _saveTreeUri(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, uri);
      setState(() => _qrTreeUri = uri);
    } catch (e) {
      print('[QRGenerator] saveTreeUri error: $e');
    }
  }

  void _generateQR() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ingresa un texto o URL')));
      return;
    }
    setState(() {
      _qrData = text;
    });
  }

  Future<Uint8List?> _captureQR() async {
    try {
      final boundary =
          _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      print('[QRGenerator] captureQR error: $e');
      return null;
    }
  }

  Future<bool> _requestStoragePermission() async {
    return await PermissionHelper.requestStoragePermission();
  }

  Future<void> _saveQR() async {
    if (_qrData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero genera un código QR')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final qrBytes = await _captureQR();
      if (qrBytes == null) {
        throw Exception('No se pudo capturar el código QR');
      }

      final hasPerm = await _requestStoragePermission();
      if (!hasPerm) {
        throw Exception('Se necesitan permisos de almacenamiento');
      }

      // Guardar temporalmente
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'qr_code_$timestamp.png';
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(qrBytes);

      // Guardar usando SAF si hay treeUri
      if (_qrTreeUri != null && _qrTreeUri!.isNotEmpty) {
        final savedUri = await SafHelper.saveFileFromPath(
          treeUri: _qrTreeUri!,
          tempPath: tempFile.path,
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
        await tempFile.copy(destPath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('QR guardado: $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[QRGenerator] saveQR error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Future<void> _shareQR() async {
    if (_qrData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero genera un código QR')),
      );
      return;
    }

    try {
      final qrBytes = await _captureQR();
      if (qrBytes == null) {
        throw Exception('No se pudo capturar el código QR');
      }

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'qr_code_$timestamp.png';
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(qrBytes);

      await Share.shareXFiles([
        XFile(tempFile.path),
      ], text: 'Código QR: $_qrData');
    } catch (e) {
      print('[QRGenerator] shareQR error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al compartir: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    const accentColor = Colors.orangeAccent;
    const cardBackgroundColor = Color(0xFF1C1C1E);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Generador QR'),
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
                final msg = _qrTreeUri ?? 'No hay carpeta seleccionada';
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
                message: _qrTreeUri == null
                    ? 'Seleccionar carpeta'
                    : 'Carpeta seleccionada',
                child: Icon(
                  Icons.folder_open,
                  color: _qrTreeUri == null
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
              // Input field
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
                        'Contenido del QR',
                        style: TextStyle(
                          color: textColor.withOpacity(0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _textController,
                        style: TextStyle(color: textColor, fontSize: 16),
                        maxLines: 3,
                        cursorColor: accentColor,
                        decoration: InputDecoration(
                          hintText: 'URL, texto, o cualquier información...',
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

              // Generate Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _generateQR,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text(
                    'Generar QR',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // QR Preview
              Expanded(
                child: Center(
                  child: _qrData.isEmpty
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.qr_code_scanner,
                              size: 64,
                              color: textColor.withOpacity(0.2),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'El código QR aparecerá aquí',
                              style: TextStyle(
                                color: textColor.withOpacity(0.4),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        )
                      : Card(
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: RepaintBoundary(
                              key: _qrKey,
                              child: QrImageView(
                                data: _qrData,
                                version: QrVersions.auto,
                                size: 250,
                                backgroundColor: Colors.white,
                                errorCorrectionLevel: QrErrorCorrectLevel.H,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Action Buttons
              if (_qrData.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isSaving ? null : _saveQR,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.save),
                        label: Text(
                          _isSaving ? 'Guardando...' : 'Guardar',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accentColor,
                          side: const BorderSide(color: accentColor, width: 2),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _shareQR,
                        icon: const Icon(Icons.share),
                        label: const Text(
                          'Compartir',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
