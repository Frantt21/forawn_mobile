// lib/screens/music_downloader_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/spotify_track.dart';
import '../services/spotify_service.dart';
import '../services/download_service.dart';
import '../services/saf_helper.dart';

class MusicDownloaderScreen extends StatefulWidget {
  const MusicDownloaderScreen({super.key});

  @override
  State<MusicDownloaderScreen> createState() => _MusicDownloaderScreenState();
}

class _MusicDownloaderScreenState extends State<MusicDownloaderScreen> {
  final TextEditingController _searchController = TextEditingController();
  final SpotifyService _spotifyService = SpotifyService();
  final DownloadService _downloadService = DownloadService();

  String? _downloadDirectory;
  String? _treeUri;
  List<SpotifyTrack> _searchResults = [];
  bool _isSearching = false;
  final Map<String, double> _downloadProgress = {};
  final Map<String, bool> _isDownloading = {};

  @override
  void initState() {
    super.initState();
    _initDownloadDirectory();
    _loadSavedTreeUri();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedTreeUri() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = prefs.getString('saf_tree_uri');
      if (uri != null && uri.isNotEmpty) {
        setState(() => _treeUri = uri);
      }
    } catch (e) {
      print('Error loading saved treeUri: $e');
    }
  }

  Future<void> _saveTreeUri(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saf_tree_uri', uri);
      setState(() => _treeUri = uri);
    } catch (e) {
      print('Error saving treeUri: $e');
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
      print('Error al seleccionar carpeta: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo seleccionar la carpeta')),
        );
      }
    }
  }

  Future<void> _initDownloadDirectory() async {
    try {
      Directory? directory;
      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/Download');
        if (!await directory.exists()) {
          directory = await getExternalStorageDirectory();
        }
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      if (directory != null) {
        setState(() {
          _downloadDirectory = directory?.path ?? '';
        });
      }
    } catch (e) {
      print('Error initializing directory: $e');
    }
  }

  Future<void> _searchSongs() async {
    final query = _searchController.text.trim();

    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor ingresa un término de búsqueda'),
        ),
      );
      return;
    }

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final results = await _spotifyService.searchSongs(query);
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });

      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontraron resultados')),
        );
      }
    } catch (e, st) {
      print('[MusicDownloaderScreen] _searchSongs error: $e');
      print(st);

      setState(() {
        _isSearching = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Error al buscar canciones. Revisa la consola para más detalles.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _downloadTrack(SpotifyTrack track) async {
    if (_downloadDirectory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Inicializando directorio de descarga...'),
        ),
      );
      await _initDownloadDirectory();
      if (_downloadDirectory == null) return;
    }

    final hasPermission = await _downloadService.requestStoragePermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se necesitan permisos de almacenamiento'),
          ),
        );
      }
      return;
    }

    setState(() {
      _isDownloading[track.url] = true;
      _downloadProgress[track.url] = 0.0;
    });

    // IMPORTANTE: Guardamos los datos del track ANTES de intentar la API
    // Estos datos vienen de la búsqueda inicial de Spotify y son confiables
    String trackName = track.title.trim();
    String artistName = track.artists.trim();

    // Si no hay artista en el track, intentamos extraerlo del título
    if (artistName.isEmpty && trackName.contains(' - ')) {
      final parts = trackName.split(' - ');
      if (parts.length >= 2) {
        artistName = parts[0].trim();
        trackName = parts.sublist(1).join(' - ').trim();
      }
    }

    print(
      '[MusicDownloaderScreen] Descargando: track="$trackName", artist="$artistName"',
    );

    String? downloadUrl;

    try {
      // Paso 1: Intentar obtener URL desde tu API
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Obteniendo enlace de descarga...')),
        );
      }

      try {
        final downloadInfo = await _spotifyService.getDownloadUrl(
          track.url,
          trackName: trackName,
          artistName: artistName,
          // imageUrl: track.imageUrl, // Modelo no tiene imageUrl aún
        );

        // Verificar que la URL de descarga no esté vacía
        if (downloadInfo.downloadUrl.isEmpty) {
          throw Exception('API devolvió URL vacía');
        }

        downloadUrl = downloadInfo.downloadUrl;

        // Actualizar nombre y artista si la API los proporciona (opcional)
        if (downloadInfo.name.isNotEmpty) {
          trackName = downloadInfo.name;
        }
        if (downloadInfo.artists.isNotEmpty) {
          artistName = downloadInfo.artists;
        }

        print(
          '[MusicDownloaderScreen] API exitosa, usando: track="$trackName", artist="$artistName"',
        );
      } catch (apiError) {
        print('[MusicDownloaderScreen] API falló: $apiError');
        // downloadUrl queda null, usaremos YouTube
        // trackName y artistName ya están definidos desde el inicio
        downloadUrl = null;
      }

      // Crear nombre de archivo limpio
      final fileName = artistName.isNotEmpty
          ? '$trackName - $artistName.mp3'
          : '$trackName.mp3';
      final cleanFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              downloadUrl != null
                  ? 'Descargando: $trackName...'
                  : 'API no disponible, buscando en YouTube...',
            ),
          ),
        );
      }

      // Paso 2: Descargar (API o YouTube fallback)
      await _downloadService.downloadAndSave(
        url: downloadUrl ?? '', // Si es null o vacío, activará YouTube
        fileName: cleanFileName,
        treeUri: _treeUri,
        onProgress: (progress) {
          setState(() {
            _downloadProgress[track.url] = progress;
          });
        },
        cancelToken: null,
        trackTitle: trackName,
        artistName: artistName,
        enableYoutubeFallback: true,
      );

      setState(() {
        _isDownloading[track.url] = false;
        _downloadProgress.remove(track.url);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Guardado: $cleanFileName'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print('[MusicDownloaderScreen] Error final: $e');

      setState(() {
        _isDownloading[track.url] = false;
        _downloadProgress.remove(track.url);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: No se pudo descargar desde ninguna fuente'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _download_service_downloadAndSaveWrapper({
    required String url,
    required String fileName,
    String? treeUri,
    required Function(double) onProgress,
  }) async {
    await _downloadService.downloadAndSave(
      url: url,
      fileName: fileName,
      treeUri: treeUri,
      onProgress: onProgress,
      cancelToken: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final textColor = theme.colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Downloader'),
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
                final uri = _treeUri;
                final msg = uri ?? 'No hay carpeta seleccionada';
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
                message: _treeUri == null
                    ? 'Seleccionar carpeta'
                    : 'Carpeta seleccionada',
                child: Icon(
                  Icons.folder_open,
                  color: _treeUri == null
                      ? Theme.of(context).appBarTheme.iconTheme?.color ??
                            Colors.white
                      : Colors.purpleAccent,
                ),
              ),
            ),
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16.0),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        // Directory info + botón cambiar carpeta
                        // Card(
                        //   child: ListTile(
                        //     leading: Icon(Icons.folder_shared, color: accentColor),
                        //     title: Text(
                        //       'Carpeta de Descargas',
                        //       style: TextStyle(
                        //         color: textColor,
                        //         fontSize: 14,
                        //         fontWeight: FontWeight.bold,
                        //       ),
                        //     ),
                        //     subtitle: Text(
                        //       _treeUri ?? _downloadDirectory ?? 'Cargando...',
                        //       style: TextStyle(
                        //         color: textColor.withOpacity(0.6),
                        //         fontSize: 12,
                        //       ),
                        //       maxLines: 1,
                        //       overflow: TextOverflow.ellipsis,
                        //     ),
                        //     trailing: TextButton.icon(
                        //       onPressed: _pickFolder,
                        //       icon: Icon(Icons.edit, color: accentColor),
                        //       label: Text('Cambiar', style: TextStyle(color: accentColor)),
                        //     ),
                        //   ),
                        // ),
                        // const SizedBox(height: 16),

                        // Search field
                        // Text(
                        //   'Buscar Música',
                        //   style: TextStyle(
                        //     color: textColor,
                        //     fontSize: 16,
                        //     fontWeight: FontWeight.bold,
                        //   ),
                        // ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: TextField(
                              controller: _searchController,
                              style: TextStyle(color: textColor),
                              decoration: InputDecoration(
                                hintText: 'Nombre de la canción o artista...',
                                hintStyle: TextStyle(
                                  color: textColor.withOpacity(0.4),
                                ),
                                border: InputBorder.none,
                                icon: Icon(Icons.search, color: accentColor),
                              ),
                              onSubmitted: (_) => _searchSongs(),
                              textInputAction: TextInputAction.search,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isSearching ? null : _searchSongs,
                            icon: _isSearching
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black,
                                    ),
                                  )
                                : const Icon(Icons.search),
                            label: Text(
                              _isSearching ? 'Buscando...' : 'Buscar',
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Results header
                        Text(
                          _searchResults.isEmpty
                              ? 'Resultados'
                              : 'Resultados (${_searchResults.length})',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ]),
                    ),
                  ),

                  // Results area usando SliverList
                  _isSearching
                      ? SliverFillRemaining(
                          hasScrollBody: false,
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : _searchResults.isEmpty
                      ? SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.music_note,
                                  size: 64,
                                  color: textColor.withOpacity(0.3),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Busca canciones para comenzar',
                                  style: TextStyle(
                                    color: textColor.withOpacity(0.5),
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final track = _searchResults[index];
                              final isDownloading =
                                  _isDownloading[track.url] ?? false;
                              final progress =
                                  _downloadProgress[track.url] ?? 0.0;

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: accentColor.withOpacity(
                                      0.2,
                                    ),
                                    child: isDownloading
                                        ? SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              value: progress,
                                              strokeWidth: 3,
                                              color: accentColor,
                                            ),
                                          )
                                        : Icon(
                                            Icons.music_note,
                                            color: accentColor,
                                          ),
                                  ),
                                  title: Text(
                                    track.title,
                                    style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${track.duration} • Popularidad: ${track.popularity}',
                                    style: TextStyle(
                                      color: textColor.withOpacity(0.6),
                                    ),
                                  ),
                                  trailing: isDownloading
                                      ? Text(
                                          '${(progress * 100).toInt()}%',
                                          style: TextStyle(
                                            color: accentColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : IconButton(
                                          icon: Icon(
                                            Icons.download,
                                            color: accentColor,
                                          ),
                                          onPressed: () =>
                                              _downloadTrack(track),
                                        ),
                                  onTap: isDownloading
                                      ? null
                                      : () => _downloadTrack(track),
                                ),
                              );
                            }, childCount: _searchResults.length),
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
