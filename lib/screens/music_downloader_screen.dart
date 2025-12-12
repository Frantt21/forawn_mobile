// lib/screens/music_downloader_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/spotify_track.dart';
import '../services/spotify_service.dart';
import '../services/saf_helper.dart';
import '../services/pinterest_service.dart';
import '../services/global_download_manager.dart';
import 'download_history_screen.dart';

class MusicDownloaderScreen extends StatefulWidget {
  const MusicDownloaderScreen({super.key});

  @override
  State<MusicDownloaderScreen> createState() => _MusicDownloaderScreenState();
}

class _MusicDownloaderScreenState extends State<MusicDownloaderScreen> {
  final TextEditingController _searchController = TextEditingController();
  final SpotifyService _spotifyService = SpotifyService();
  final GlobalDownloadManager _downloadManager = GlobalDownloadManager();

  String? _treeUri;
  List<SpotifyTrack> _searchResults = [];
  bool _isSearching = false;
  final Map<String, String?> _pinterestImages = {}; // Cache de imágenes de Pinterest

  @override
  void initState() {
    super.initState();
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
      _pinterestImages.clear(); // Limpiar cache de imágenes anteriores
    });

    try {
      final results = await _spotifyService.searchSongs(query);
      
      // Mostrar resultados INMEDIATAMENTE
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });

      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontraron resultados')),
        );
        return;
      }

      // Cargar imágenes de Pinterest de forma ASÍNCRONA (en segundo plano)
      _loadPinterestImages(results);
      
    } catch (e, st) {
      print('[MusicDownloaderScreen] _searchSongs error: $e');
      print(st);

      setState(() {
        _isSearching = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al buscar: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Cargar imágenes de Pinterest de forma asíncrona
  Future<void> _loadPinterestImages(List<SpotifyTrack> tracks) async {
    for (final track in tracks) {
      if (!mounted) break; // Detener si el widget fue destruido

      try {
        // Construir query: "artista canción portada"
        final searchQuery = '${track.artists} ${track.title} portada';
        
        // Buscar imagen en Pinterest
        final imageUrl = await PinterestService.getFirstImage(searchQuery);
        
        // Actualizar UI con la imagen encontrada
        if (mounted && imageUrl != null) {
          setState(() {
            _pinterestImages[track.url] = imageUrl;
          });
        }
      } catch (e) {
        print('[MusicDownloaderScreen] Error loading Pinterest image for ${track.title}: $e');
        // Continuar con la siguiente canción si falla
      }
    }
  }

  Future<void> _downloadTrack(SpotifyTrack track) async {
    try {
      // Agregar descarga al gestor global
      final downloadId = await _downloadManager.addDownload(
        track: track,
        pinterestImageUrl: _pinterestImages[track.url],
        treeUri: _treeUri,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Descarga iniciada: ${track.title}'),
            action: SnackBarAction(
              label: 'Ver',
              onPressed: () {
                // TODO: Navegar a pantalla de descargas activas
              },
            ),
          ),
        );
      }

      print('[MusicDownloaderScreen] Download added with ID: $downloadId');
    } catch (e) {
      print('[MusicDownloaderScreen] Error adding download: $e');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar descarga: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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
          // Botón de historial
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const DownloadHistoryScreen(),
                ),
              );
            },
            tooltip: 'Historial de descargas',
          ),
          // Botón de carpeta
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
                              final pinterestImage = _pinterestImages[track.url];

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: 56,
                                      height: 56,
                                      color: accentColor.withOpacity(0.2),
                                      child: pinterestImage != null
                                          ? Image.network(
                                              pinterestImage,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => Icon(
                                                Icons.music_note,
                                                color: accentColor,
                                              ),
                                              loadingBuilder: (context, child, loadingProgress) {
                                                if (loadingProgress == null) return child;
                                                return Center(
                                                  child: CircularProgressIndicator(
                                                    value: loadingProgress.expectedTotalBytes != null
                                                        ? loadingProgress.cumulativeBytesLoaded /
                                                            loadingProgress.expectedTotalBytes!
                                                        : null,
                                                    strokeWidth: 2,
                                                    color: accentColor,
                                                  ),
                                                );
                                              },
                                            )
                                          : Icon(
                                              Icons.music_note,
                                              color: accentColor,
                                            ),
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
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.download,
                                      color: accentColor,
                                    ),
                                    onPressed: () => _downloadTrack(track),
                                  ),
                                  onTap: () => _downloadTrack(track),
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
