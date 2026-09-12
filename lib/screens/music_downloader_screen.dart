import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/spotify_track.dart';
import '../services/innertube_service.dart';
import '../services/saf_helper.dart';
import '../services/global_download_manager.dart';
import '../services/language_service.dart';
import 'download_history_screen.dart';

class MusicDownloaderScreen extends StatefulWidget {
  const MusicDownloaderScreen({super.key});

  @override
  State<MusicDownloaderScreen> createState() => _MusicDownloaderScreenState();
}

class _MusicDownloaderScreenState extends State<MusicDownloaderScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final GlobalDownloadManager _downloadManager = GlobalDownloadManager();

  String? _treeUri;
  List<InnertubeTrack> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false; // Indica si ya se realizó una búsqueda
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _loadSavedTreeUri();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _animationController.dispose();
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
            SnackBar(
              content: Text(LanguageService().getText('folder_selected')),
            ),
          );
        }
      }
    } catch (e) {
      print('Error al seleccionar carpeta: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('folder_select_error')),
          ),
        );
      }
    }
  }

  Future<void> _searchSongs() async {
    final query = _searchController.text.trim();

    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LanguageService().getText('enter_search_term'))),
      );
      return;
    }

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      // Búsqueda directa por Innertube (YT Music + fallback WEB):
      // título/artista limpios, artwork cuadrado y videoId exacto — sin
      // servidores propios. Reutiliza la lógica de Forawn desktop.
      final results = await InnertubeService().searchTracks(query, limit: 20);

      setState(() {
        _searchResults = results;
        _isSearching = false;
        _hasSearched = true; // Marcar que ya se buscó
      });

      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('no_results_found')),
          ),
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
          SnackBar(
            content: Text(
              '${LanguageService().getText('search_error')}: ${e.toString()}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _downloadTrack(InnertubeTrack video) async {
    try {
      // El resultado de Innertube ya trae videoId exacto, título y artista
      // limpios y artwork cuadrado. La descarga la hace yt-dlp+ffmpeg
      // embebidos (YtDlpService) incrustando estos metadatos.
      _showDownloadAddedAnimation(video.rawTitle);

      print('[MusicDownloaderScreen] 🎵 Downloading:');
      print('[MusicDownloaderScreen]   - videoId: ${video.videoId}');
      print('[MusicDownloaderScreen]   - Title: ${video.rawTitle}');

      final track = SpotifyTrack(
        title: video.rawTitle,
        artists: video.channel,
        url: video.watchUrl, // ✅ watch?v=VIDEOID exacto del resultado
        duration:
            '${video.durationMs ~/ 60000}:${((video.durationMs % 60000) ~/ 1000).toString().padLeft(2, '0')}',
        popularity: '0',
      );

      final downloadId = await _downloadManager.addDownload(
        track: track,
        pinterestImageUrl: video.thumbnailUrl,
        treeUri: _treeUri,
      );

      print(
        '[MusicDownloaderScreen] ✅ Download added with exact videoId: $downloadId',
      );
    } catch (e) {
      print('[MusicDownloaderScreen] Error adding download: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showDownloadAddedAnimation(String title) {
    if (!mounted) return;

    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 60,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            builder: (context, value, child) {
              // Clamp value to ensure it's within valid range
              final clampedValue = value.clamp(0.0, 1.0);
              return Transform.scale(
                scale: clampedValue,
                child: Opacity(opacity: clampedValue, child: child),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C), // Color oscuro tipo tarjeta
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min, // Ajustar al contenido
                children: [
                  const Icon(
                    Icons.download_rounded,
                    color: Colors.purpleAccent, // Acento sutil
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Download added',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(), // Empujar botón a la derecha si es ancho completo, o remover spacer para compacto
                  TextButton(
                    onPressed: () {
                      overlayEntry.remove();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const DownloadHistoryScreen(),
                        ),
                      );
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      LanguageService().getText('view'), // 'Ver'
                      style: const TextStyle(
                        color: Colors.purpleAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    // Remover después de 3 segundos
    Future.delayed(const Duration(seconds: 3), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final textColor = theme.colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(
        title: Text(LanguageService().getText('music_downloader')),
        actions: [
          // Solo mostrar icono de búsqueda cuando ya se ha buscado
          if (_hasSearched)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                setState(() {
                  _hasSearched = false;
                  _searchResults = [];
                  _searchController.clear();
                });
              },
              tooltip: LanguageService().getText('search'),
            ),
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
            tooltip: LanguageService().getText('download_history'),
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
                        SnackBar(
                          content: Text(
                            LanguageService().getText('folder_selected'),
                          ),
                        ),
                      );
                    }
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          LanguageService().getText('folder_select_error'),
                        ),
                      ),
                    );
                  }
                }
              },
              onLongPress: () {
                final uri = _treeUri;
                final msg =
                    uri ?? LanguageService().getText('no_folder_selected');
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
                    ? LanguageService().getText('select_folder')
                    : LanguageService().getText('folder_selected_tooltip'),
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
                  // Campo de búsqueda - solo visible si NO se ha buscado
                  if (!_hasSearched)
                    SliverPadding(
                      padding: const EdgeInsets.all(16.0),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          const SizedBox(height: 12),
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: TextField(
                                controller: _searchController,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                                cursorColor: Colors.purpleAccent,
                                decoration: InputDecoration(
                                  hintText: LanguageService().getText(
                                    'song_or_artist',
                                  ),
                                  hintStyle: TextStyle(
                                    color: Colors.white.withOpacity(0.3),
                                    fontSize: 16,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search,
                                    color: Colors.white.withOpacity(0.5),
                                    size: 20,
                                  ),
                                  suffixIcon: _searchController
                                          .text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(
                                            Icons.close,
                                            color: Colors.white54,
                                            size: 20,
                                          ),
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {});
                                          },
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                onSubmitted: (_) => _searchSongs(),
                                textInputAction: TextInputAction.search,
                              ),
                            ),
                          ),
                          // const SizedBox(height: 16),
                          // SizedBox(
                          //   width: double.infinity,
                          //   child: ElevatedButton.icon(
                          //     onPressed: _isSearching ? null : _searchSongs,
                          //     icon: _isSearching
                          //         ? const SizedBox(
                          //             width: 20,
                          //             height: 20,
                          //             child: CircularProgressIndicator(
                          //               strokeWidth: 2,
                          //               color: Colors.black,
                          //             ),
                          //           )
                          //         : const Icon(Icons.search),
                          //     label: Text(
                          //       _isSearching
                          //           ? LanguageService().getText('searching')
                          //           : LanguageService().getText('search'),
                          //     ),
                          //   ),
                          // ),
                          // const SizedBox(height: 24),
                        ]),
                      ),
                    ),

                  // Results header
                  if (_searchResults.isNotEmpty || _isSearching)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          Text(
                            _searchResults.isEmpty
                                ? LanguageService().getText('results')
                                : '${LanguageService().getText('results')} (${_searchResults.length})',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  _isSearching
                      ? SliverFillRemaining(
                          hasScrollBody: false,
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : _searchResults.isEmpty && !_hasSearched
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
                                  LanguageService().getText('search_to_start'),
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
                              final video = _searchResults[index];

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: 56,
                                      height: 56,
                                      color: accentColor.withOpacity(0.2),
                                      child: video.thumbnailUrl.isNotEmpty
                                          ? Image.network(
                                              video.thumbnailUrl,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Icon(
                                                    Icons.music_note,
                                                    color: accentColor,
                                                  ),
                                            )
                                          : Icon(
                                              Icons.music_note,
                                              color: accentColor,
                                            ),
                                    ),
                                  ),
                                  title: Text(
                                    video.rawTitle,
                                    style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${video.channel} • ${video.album.isNotEmpty ? '${video.album} • ' : ''}${video.durationMs ~/ 60000}:${((video.durationMs % 60000) ~/ 1000).toString().padLeft(2, '0')}',
                                    style: TextStyle(
                                      color: textColor.withOpacity(0.6),
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.download,
                                      color: accentColor,
                                    ),
                                    tooltip: 'Download',
                                    onPressed: () => _downloadTrack(video),
                                  ),
                                  onTap: () => _downloadTrack(video),
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
