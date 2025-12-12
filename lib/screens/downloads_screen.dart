// lib/screens/downloads_screen.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

// imports adicionales al inicio del archivo downloads_screen.dart
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mime/mime.dart'; // para detectar mime type (añadir dependencia mime: ^1.0.0 si no la tienes)

import 'package:audiotags/audiotags.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';

enum DownloadsType { images, music }

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DownloadsType _selected = DownloadsType.images;

  // SharedPreferences keys (mismatched con Music/Images screens)
  static const _imagesKey = 'saf_tree_uri_images';
  static const _musicKey = 'saf_tree_uri';

  String? _imagesTreeUri;
  String? _musicTreeUri;

  // Lists for each type: dynamic to hold FileSystemEntity or Map (SAF)
  List<dynamic> _imageFiles = [];
  List<dynamic> _musicFiles = [];

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _selected = _tabController.index == 0
              ? DownloadsType.images
              : DownloadsType.music;
        });
        _loadUrisAndFiles();
      }
    });
    _loadUrisAndFiles();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadUrisAndFiles() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      _imagesTreeUri = prefs.getString(_imagesKey);
      _musicTreeUri = prefs.getString(_musicKey);

      await Future.wait([
        _loadFiles(DownloadsType.images),
        _loadFiles(DownloadsType.music),
      ]);
    } catch (e) {
      print('Error loading: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFiles(DownloadsType type) async {
    final uri = type == DownloadsType.images ? _imagesTreeUri : _musicTreeUri;
    List<dynamic> newFiles = [];

    try {
      if (uri == null || uri.isEmpty) {
        final fallback = Directory('/storage/emulated/0/Download');
        if (await fallback.exists()) {
          final all = fallback.listSync();
          newFiles = _filterByType(all, type);
        }
      } else if (uri.startsWith('/')) {
        final dir = Directory(uri);
        if (await dir.exists()) {
          final all = dir.listSync();
          newFiles = _filterByType(all, type);
        }
      } else {
        // SAF
        final list = await SafHelper.listFilesFromTree(uri);
        if (list != null) {
          final entries = List<Map<String, String>>.from(list);
          newFiles = entries.where((e) {
            final name = e['name']?.toLowerCase() ?? '';
            if (type == DownloadsType.images) {
              return name.endsWith('.jpg') ||
                  name.endsWith('.jpeg') ||
                  name.endsWith('.png') ||
                  name.endsWith('.webp') ||
                  name.endsWith('.gif') ||
                  name.endsWith('.heic');
            } else {
              return name.endsWith('.mp3') ||
                  name.endsWith('.m4a') ||
                  name.endsWith('.wav') ||
                  name.endsWith('.aac') ||
                  name.endsWith('.ogg') ||
                  name.endsWith('.flac');
            }
          }).toList();
        }
      }
    } catch (e) {
      print('Error listing files for $type: $e');
    }

    if (mounted) {
      setState(() {
        if (type == DownloadsType.images) {
          _imageFiles = newFiles;
        } else {
          _musicFiles = newFiles;
        }
      });
    }
  }

  Future<void> _openFile(dynamic f) async {
    try {
      if (f is FileSystemEntity) {
        final path = f.path;
        // open_file package
        await OpenFile.open(path);
        return;
      }

      if (f is Map<String, String>) {
        final uri = f['uri'] ?? '';
        if (uri.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('URI inválida')));
          return;
        }
        // Intent nativo para abrir content:// URI
        final ok = await SafHelper.openFileFromUri(uri);
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo abrir el archivo SAF')),
          );
        }
        return;
      }
    } catch (e) {
      print('[DownloadsScreen] _openFile error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error al abrir el archivo')),
      );
    }
  }

  List<FileSystemEntity> _filterByType(
    List<FileSystemEntity> all,
    DownloadsType type,
  ) {
    final imageExt = [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp',
      '.heic',
    ];
    final audioExt = ['.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac'];

    final filtered = all.where((f) {
      if (f is File) {
        final ext = p.extension(f.path).toLowerCase();
        if (type == DownloadsType.images) return imageExt.contains(ext);
        return audioExt.contains(ext);
      }
      return false;
    }).toList();

    filtered.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });

    return filtered;
  }

  Future<void> _pickFolderForSelected() async {
    try {
      final picked = await SafHelper.pickDirectory();
      if (picked != null) {
        final prefs = await SharedPreferences.getInstance();
        if (_selected == DownloadsType.images) {
          await prefs.setString(_imagesKey, picked);
          _imagesTreeUri = picked;
        } else {
          await prefs.setString(_musicKey, picked);
          _musicTreeUri = picked;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Carpeta seleccionada correctamente')),
        );
        await _loadFiles(_selected);
      }
    } catch (e) {
      print('[DownloadsScreen] pickFolder error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo seleccionar la carpeta')),
      );
    }
  }

  Widget _buildFileTile(dynamic f) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;

    // Local file
    if (f is FileSystemEntity) {
      final name = p.basename(f.path);
      String subtitle;
      try {
        final modified = f.statSync().modified;
        subtitle = '${modified.toLocal()}'.split('.').first;
      } catch (_) {
        subtitle = '';
      }
      final isImage = [
        '.jpg',
        '.jpeg',
        '.png',
        '.webp',
        '.gif',
        '.bmp',
        '.heic',
      ].contains(p.extension(f.path).toLowerCase());

      return Card(
        child: ListTile(
          leading: isImage
              ? SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(f.path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image),
                    ),
                  ),
                )
              : const CircleAvatar(child: Icon(Icons.music_note)),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: textColor.withOpacity(0.6)),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showFileOptions(f),
          ),
          onTap: () => _openFile(f),
        ),
      );
    }

    // SAF entry (Map with 'name' and 'uri')
    if (f is Map<String, String>) {
      final name = f['name'] ?? 'Archivo';
      final uri = f['uri'] ?? '';
      final lower = name.toLowerCase();
      final isImage =
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');

      return Card(
        child: ListTile(
          leading: isImage
              ? SizedBox(
                  width: 56,
                  height: 56,
                  child: FutureBuilder<Uint8List?>(
                    future: SafHelper.readBytesFromUri(
                      uri,
                      maxBytes: 256 * 1024,
                    ), // 256KB max para thumbnail
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      if (snapshot.hasData && snapshot.data != null) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.memory(
                            snapshot.data!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.image,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.6,
                              ),
                            ),
                          ),
                        );
                      }
                      return Icon(
                        Icons.image,
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      );
                    },
                  ),
                )
              : const CircleAvatar(child: Icon(Icons.insert_drive_file)),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            uri,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor.withOpacity(0.6)),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showSafFileOptions(name, uri),
          ),
          onTap: () => _openFile(f),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  // Future<void> _openFile(FileSystemEntity f) async {
  //   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Abrir: ${p.basename(f.path)}')));
  // }

  void _showFileOptions(FileSystemEntity f) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Abrir'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openFile(f);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Eliminar'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await f.delete();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Archivo eliminado')),
                    );
                    await _loadFiles(_selected);
                  } catch (e) {
                    print('[DownloadsScreen] delete local error: $e');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo eliminar el archivo'),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Compartir'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final path = f.path;
                    final mimeType =
                        lookupMimeType(path) ?? 'application/octet-stream';
                    await Share.shareXFiles([
                      XFile(path),
                    ], text: p.basename(path));
                  } catch (e) {
                    print('[DownloadsScreen] share local error: $e');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo compartir el archivo'),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSafFileOptions(String name, String uri) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Abrir'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await SafHelper.openFileFromUri(uri);
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo abrir el archivo SAF'),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Eliminar'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dctx) => AlertDialog(
                      title: const Text('Eliminar archivo'),
                      content: Text('¿Eliminar "$name"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('Cancelar'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          child: const Text('Eliminar'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  final ok = await SafHelper.deleteFileFromUri(uri);
                  if (ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Archivo eliminado')),
                    );
                    await _loadFiles(_selected);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo eliminar el archivo SAF'),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Compartir'),
                onTap: () async {
                  Navigator.pop(ctx);
                  // Intent nativo para compartir content:// URI
                  // Intentará inferir mime desde el nombre
                  final mimeType =
                      lookupMimeType(name) ?? 'application/octet-stream';
                  final ok = await SafHelper.shareFileFromUri(
                    uri,
                    mimeType,
                    name,
                  );
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo compartir el archivo SAF'),
                      ),
                    );
                  }
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
    final textColor = theme.colorScheme.onSurface;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(
                  0.5,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: theme.colorScheme.primary,
                ),
                labelColor: Colors.white,
                unselectedLabelColor: textColor,
                dividerColor: Colors.transparent,
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: const [
                  Tab(text: "Imágenes"),
                  Tab(text: "Música"),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildFileList(DownloadsType.images),
                  _buildFileList(DownloadsType.music),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(DownloadsType type) {
    final list = type == DownloadsType.images ? _imageFiles : _musicFiles;
    final currentTreeUri = type == DownloadsType.images
        ? _imagesTreeUri
        : _musicTreeUri;

    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(child: Text(_error!));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  currentTreeUri ?? 'Ninguna carpeta seleccionada',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacity(0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.folder_open),
                onPressed: _pickFolderForSelected,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_off,
                        size: 48,
                        color: textColor.withOpacity(0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "No hay archivos",
                        style: TextStyle(color: textColor.withOpacity(0.5)),
                      ),
                      if (currentTreeUri == null)
                        TextButton(
                          onPressed: _pickFolderForSelected,
                          child: const Text("Seleccionar Carpeta"),
                        ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _loadFiles(type),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _buildItem(list[i], type),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildItem(dynamic item, DownloadsType type) {
    if (type == DownloadsType.music) {
      return _MusicTile(
        file: item,
        onTap: () => _openFile(item),
        onMore: () => item is FileSystemEntity
            ? _showFileOptions(item)
            : _showSafFileOptions(item['name']!, item['uri']!),
        theme: Theme.of(context),
      );
    }
    return _buildFileTile(item);
  }
}

class _MusicTile extends StatefulWidget {
  final dynamic file; // FileSystemEntity or Map
  final VoidCallback onTap;
  final VoidCallback onMore;
  final ThemeData theme;

  const _MusicTile({
    required this.file,
    required this.onTap,
    required this.onMore,
    required this.theme,
  });

  @override
  State<_MusicTile> createState() => _MusicTileState();
}

class _MusicTileState extends State<_MusicTile>
    with AutomaticKeepAliveClientMixin {
  String? _artist;
  String? _album;
  Uint8List? _art;
  int? _durationMs;
  bool _isLoading = false;
  bool _isLoaded = false;

  @override
  bool get wantKeepAlive => true; // Mantener widget vivo al hacer scroll

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    // Evitar cargas múltiples
    if (_isLoading || _isLoaded) return;
    _isLoading = true;

    try {
      final cacheKey = widget.file is FileSystemEntity
          ? (widget.file as FileSystemEntity).path
          : (widget.file as Map)['uri'] ?? '';

      final fileName = widget.file is FileSystemEntity
          ? p.basename((widget.file as FileSystemEntity).path)
          : (widget.file as Map)['name'] ?? 'unknown';

      // 1. Intentar obtener del caché
      final cached = await MusicMetadataCache.get(cacheKey);
      if (cached != null) {
        if (mounted) {
          setState(() {
            _artist = cached.artist;
            _album = cached.album;
            _art = cached.artwork;
            _durationMs = cached.durationMs;
            _isLoaded = true;
          });
        }
        _isLoading = false;
        return;
      }

      // 2. Cargar metadata desde archivo (solo si no está en caché)
      print('[MusicTile] Loading: $fileName');
      Tag? tag;

      if (widget.file is FileSystemEntity) {
        final path = (widget.file as FileSystemEntity).path;
        tag = await AudioTags.read(path);
      } else if (widget.file is Map) {
        final uri = (widget.file as Map)['uri'];
        if (uri != null) {
          final bytes = await SafHelper.readBytesFromUri(
            uri,
            maxBytes: 1 * 1024 * 1024,
          );
          if (bytes != null && bytes.isNotEmpty) {
            final tempDir = Directory.systemTemp;
            final extension = p.extension(fileName);
            final tempFile = File(
              '${tempDir.path}/temp_audio_${DateTime.now().millisecondsSinceEpoch}$extension',
            );

            try {
              await tempFile.writeAsBytes(bytes);
              tag = await AudioTags.read(tempFile.path);
            } finally {
              if (await tempFile.exists()) {
                await tempFile.delete();
              }
            }
          }
        }
      }

      if (tag != null) {
        // Guardar en caché
        await MusicMetadataCache.save(cacheKey, tag);

        Uint8List? artwork;
        if (tag.pictures != null && tag.pictures!.isNotEmpty) {
          artwork = tag.pictures!.first.bytes;
        }

        if (mounted) {
          setState(() {
            _artist = tag!.trackArtist ?? tag.albumArtist;
            _album = tag.album;
            _art = artwork;
            _durationMs = tag.duration != null ? (tag.duration! * 1000).toInt() : null;
            _isLoaded = true;
          });
        }
      }
    } catch (e) {
      print('[MusicTile] Error: $e');
    } finally {
      _isLoading = false;
    }
  }

  String _formatDuration(int? ms) {
    if (ms == null) return '';
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Requerido por AutomaticKeepAliveClientMixin
    final textColor = widget.theme.colorScheme.onSurface;
    final name = widget.file is FileSystemEntity
        ? p.basename((widget.file as FileSystemEntity).path)
        : (widget.file as Map)['name'] ?? 'Audio';

    // Construct subtitle
    final List<String> parts = [];
    if (_artist != null) parts.add(_artist!);
    if (_album != null) parts.add(_album!);
    final subtitleText = parts.isNotEmpty ? parts.join(' • ') : 'Desconocido';
    final durationText = _formatDuration(_durationMs);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: SizedBox(
          width: 50,
          height: 50,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _art != null
                ? Image.memory(_art!, fit: BoxFit.cover)
                : Container(
                    color: widget.theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.music_note,
                      color: widget.theme.colorScheme.primary,
                    ),
                  ),
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: textColor.withOpacity(0.7)),
            ),
            if (durationText.isNotEmpty)
              Text(
                durationText,
                style: TextStyle(
                  fontSize: 10,
                  color: textColor.withOpacity(0.5),
                ),
              ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: widget.onMore,
        ),
        onTap: widget.onTap,
      ),
    );
  }
}
