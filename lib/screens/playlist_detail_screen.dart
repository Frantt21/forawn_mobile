import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import '../services/playlist_service.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../utils/text_utils.dart';
import '../widgets/lazy_music_tile.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_options_bottom_sheet.dart';
import '../services/music_metadata_cache.dart';
import 'music_player_screen.dart';
import 'package:image_picker/image_picker.dart';
import '../services/metadata_service.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final ScrollController _scrollController = ScrollController();
  Color? _dominantColor;
  double _imageScale = 1.0;

  // Estado local para manejar favoritos (que no están en PlaylistService._playlists)
  late List<Song> _virtualSongs;
  String? _lastImagePath; // Track last image path to detect real changes

  // Búsqueda
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _virtualSongs = widget.playlist.songs;
    _lastImagePath = widget.playlist.imagePath; // Initialize with current image
    PlaylistService().addListener(_onPlaylistChanged);
    _loadCachedColorOrExtract();
    _scrollController.addListener(_onScroll);

    // Inicializar animación de búsqueda
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Preload metadata for smoother scrolling
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadMetadata();
    });
  }

  Future<void> _preloadMetadata() async {
    // Preload first 50 items or all if small playlist
    final count = _virtualSongs.length > 50 ? 50 : _virtualSongs.length;
    final requests = _virtualSongs.take(count).map((song) {
      return MetadataLoadRequest(
        id: song.filePath.hashCode.toString(),
        filePath: song.filePath.startsWith('content://') ? null : song.filePath,
        safUri: song.filePath.startsWith('content://') ? song.filePath : null,
        priority: MetadataPriority
            .low, // Low so it doesn't block High priority load from visible tiles
      );
    }).toList();

    await MetadataService().preloadMetadata(requests);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _animationController.dispose();
    PlaylistService().removeListener(_onPlaylistChanged);
    super.dispose();
  }

  void _onScroll() {
    // Calcular el scale de la imagen basado en el scroll
    // Cuando scroll = 0, scale = 1.0 (300px)
    // Cuando scroll = 300, scale = 0.5 (150px)
    final offset = _scrollController.offset;
    final newScale = (1.0 - (offset / 600)).clamp(0.5, 1.0);

    if (newScale != _imageScale) {
      setState(() {
        _imageScale = newScale;
      });
    }
  }

  void _onPlaylistChanged() {
    if (mounted) {
      // Detectar si cambió la imagen de la playlist
      final updatedPlaylist = _currentPlaylist;
      // Only reload color if image path actually changed
      if (updatedPlaylist.imagePath != _lastImagePath) {
        _lastImagePath = updatedPlaylist.imagePath;
        // La imagen cambió, recalcular color dominante
        _loadCachedColorOrExtract();
      }
      setState(() {});
    }
  }

  Playlist get _currentPlaylist {
    // Si es favoritos, no está en la lista de BD, usamos la local o widget
    if (widget.playlist.id == 'favorites_virtual') {
      return widget.playlist.copyWith(songs: _virtualSongs);
    }

    try {
      return PlaylistService().playlists.firstWhere(
        (p) => p.id == widget.playlist.id,
      );
    } catch (e) {
      return widget.playlist;
    }
  }

  /// Calcula la duración total de la playlist cargando desde caché si es necesario
  Future<Duration> _getTotalDurationFromCache() async {
    int totalMs = 0;

    for (var song in _currentPlaylist.songs) {
      // Si la canción ya tiene duración, usarla
      if (song.duration != null) {
        totalMs += song.duration!.inMilliseconds;
      } else {
        // Intentar cargar desde caché
        final cachedMetadata = await MusicMetadataCache.get(song.id);
        if (cachedMetadata != null && cachedMetadata.durationMs != null) {
          totalMs += cachedMetadata.durationMs!;
        }
      }
    }

    return Duration(milliseconds: totalMs);
  }

  Future<void> _loadCachedColorOrExtract() async {
    // Intentar cargar color cacheado
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'playlist_color_${widget.playlist.id}';
    final cachedColorValue = prefs.getInt(cacheKey);

    if (cachedColorValue != null) {
      // Usar color cacheado
      if (mounted) {
        setState(() {
          _dominantColor = Color(cachedColorValue);
        });
      }
    } else {
      // Extraer y cachear
      await _extractDominantColor();
    }
  }

  Future<void> _extractDominantColor() async {
    try {
      ImageProvider? imageProvider;
      final currentPlaylist = _currentPlaylist;

      if (currentPlaylist.imagePath != null) {
        if (File(currentPlaylist.imagePath!).existsSync()) {
          imageProvider = FileImage(File(currentPlaylist.imagePath!));
        } else {
          imageProvider = NetworkImage(currentPlaylist.imagePath!);
        }
      }

      if (imageProvider != null) {
        final PaletteGenerator paletteGenerator =
            await PaletteGenerator.fromImageProvider(
              imageProvider,
              size: const Size(200, 200),
              maximumColorCount: 20,
            );

        final extractedColor =
            paletteGenerator.dominantColor?.color ??
            paletteGenerator.vibrantColor?.color ??
            Colors.purple;

        // Oscurecer el color para que no sea tan chillón
        final darkenedColor = _darkenColor(extractedColor, 0.4);

        // Guardar en caché con la clave correcta
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'playlist_color_${currentPlaylist.id}';
        await prefs.setInt(cacheKey, darkenedColor.value);

        if (mounted) {
          setState(() {
            _dominantColor = darkenedColor;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _dominantColor = Colors.purple;
          });
        }
      }
    } catch (e) {
      print('[PlaylistDetail] Error extracting color: $e');
      if (mounted) {
        setState(() {
          _dominantColor = Colors.purple;
        });
      }
    }
  }

  /// Oscurece un color en el porcentaje especificado (0.0 - 1.0)
  Color _darkenColor(Color color, double amount) {
    assert(amount >= 0 && amount <= 1);

    final hsl = HSLColor.fromColor(color);
    // Reducir la luminosidad
    final darkened = hsl.withLightness(
      (hsl.lightness * (1 - amount)).clamp(0.0, 1.0),
    );
    return darkened.toColor();
  }

  /// Calcula si el texto debe ser blanco o negro basado en la luminancia del fondo
  Color _getTextColor(Color backgroundColor) {
    // Calcular luminancia relativa (0.0 = negro, 1.0 = blanco)
    final luminance = backgroundColor.computeLuminance();

    // Si la luminancia es mayor a 0.5, usar texto negro, sino blanco
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  void _removeSong(Song song) {
    if (widget.playlist.id == 'favorites_virtual') {
      // Manejo especial para favoritos
      PlaylistService().toggleLike(song.id);
      setState(() {
        _virtualSongs = List.from(_virtualSongs)
          ..removeWhere((s) => s.id == song.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${song.title} ${LanguageService().getText('song_removed_favorites')}",
          ),
        ),
      );
    } else {
      // Playlist normal
      PlaylistService().removeSongFromPlaylist(widget.playlist.id, song.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${song.title} ${LanguageService().getText('song_removed')}",
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  List<Song> _getFilteredSongs(List<Song> songs) {
    if (_searchQuery.isEmpty) {
      return songs;
    }

    final query = _searchQuery.toLowerCase();
    return songs.where((song) {
      return song.title.toLowerCase().contains(query) ||
          (song.artist.toLowerCase().contains(query) ?? false) ||
          (song.album?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  Widget _buildSearchField(Color textColor) {
    return AnimatedBuilder(
      key: const ValueKey('search'),
      animation: _animationController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(
            (1 - _fadeAnimation.value) * 300,
            0,
          ), // Slide from right
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: textColor, fontSize: 16),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: LanguageService().getText('search_songs'),
                hintStyle: TextStyle(
                  color: textColor.withOpacity(0.5),
                  fontSize: 16,
                ),
                prefixIcon: Icon(Icons.search, color: textColor, size: 20),
                filled: true,
                fillColor: textColor.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: textColor.withOpacity(0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditPlaylistDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    String? selectedImagePath = playlist.imagePath;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  decoration: BoxDecoration(
                    color: Colors.grey[900]!.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Título
                          Text(
                            LanguageService().getText('edit_playlist'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Imagen cuadrada más grande
                          Center(
                            child: GestureDetector(
                              onTap: () async {
                                final picker = ImagePicker();
                                final image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                );
                                if (image != null) {
                                  setState(
                                    () => selectedImagePath = image.path,
                                  );
                                }
                              },
                              child: Container(
                                width: 180,
                                height: 180,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1E),
                                  borderRadius: BorderRadius.circular(16),
                                  image: selectedImagePath != null
                                      ? DecorationImage(
                                          image:
                                              File(
                                                selectedImagePath!,
                                              ).existsSync()
                                              ? FileImage(
                                                  File(selectedImagePath!),
                                                )
                                              : NetworkImage(selectedImagePath!)
                                                    as ImageProvider,
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: selectedImagePath == null
                                    ? const Icon(
                                        Icons.add_photo_alternate,
                                        color: Colors.white54,
                                        size: 56,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Input de nombre estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_name'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: nameController,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_name',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Input de descripción estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_desc'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: descController,
                                    maxLines: 3,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_desc',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Botones
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(
                                  LanguageService().getText('cancel'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purpleAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  if (nameController.text.isNotEmpty) {
                                    await PlaylistService().updatePlaylist(
                                      playlist.id,
                                      name: nameController.text,
                                      description: descController.text,
                                      imagePath: selectedImagePath,
                                    );

                                    // Recalcular color dominante si cambió la imagen
                                    if (selectedImagePath !=
                                        playlist.imagePath) {
                                      await _extractDominantColor();
                                    }

                                    if (mounted) Navigator.pop(ctx);
                                  }
                                },
                                child: Text(
                                  LanguageService().getText('save'),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;
    final songs = playlist.songs;

    // Si es normal y fue borrada
    if (widget.playlist.id != 'favorites_virtual' &&
        !PlaylistService().playlists.any((p) => p.id == widget.playlist.id)) {
      Navigator.pop(context);
      return Container();
    }

    ImageProvider? coverImage;
    if (playlist.imagePath != null) {
      if (File(playlist.imagePath!).existsSync()) {
        coverImage = FileImage(File(playlist.imagePath!));
      } else {
        coverImage = NetworkImage(playlist.imagePath!);
      }
    }

    final backgroundColor = _dominantColor ?? Colors.purple;
    final textColor = _getTextColor(backgroundColor);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: _isSearching
              ? _buildSearchField(textColor)
              : const SizedBox.shrink(key: ValueKey('empty')),
        ),
        actions: [
          // Botón de búsqueda
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: textColor,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (_isSearching) {
                  _animationController.forward();
                } else {
                  _animationController.reverse();
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          // Menú de 3 puntos (solo si no está buscando)
          if (!_isSearching)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: textColor),
              color: Colors.grey[900],
              onSelected: (value) {
                switch (value) {
                  case 'shuffle':
                    if (songs.isNotEmpty) {
                      _audioPlayer.toggleShuffle();
                      _audioPlayer.loadPlaylist(
                        songs,
                        initialIndex: 0,
                        autoPlay: true,
                      );
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const MusicPlayerScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                var tween = Tween(
                                  begin: const Offset(0.0, 1.0),
                                  end: Offset.zero,
                                ).chain(CurveTween(curve: Curves.easeOutCubic));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    }
                    break;
                  case 'sort_title':
                    setState(() {
                      songs.sort(
                        (a, b) => a.title.toLowerCase().compareTo(
                          b.title.toLowerCase(),
                        ),
                      );
                    });
                    break;
                  case 'sort_artist':
                    setState(() {
                      songs.sort(
                        (a, b) => (a.artist ?? '').toLowerCase().compareTo(
                          (b.artist ?? '').toLowerCase(),
                        ),
                      );
                    });
                    break;
                  case 'sort_date':
                    // Restaurar orden original (orden de agregado)
                    setState(() {
                      if (widget.playlist.id == 'favorites_virtual') {
                        _virtualSongs = List.from(widget.playlist.songs);
                      }
                    });
                    break;
                  case 'edit_playlist':
                    _showEditPlaylistDialog(context, _currentPlaylist);
                    break;
                  case 'add_songs':
                    // TODO: Implementar agregar canciones
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(LanguageService().getText('add_songs')),
                      ),
                    );
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'shuffle',
                  child: Row(
                    children: [
                      const Icon(Icons.shuffle, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('shuffle'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'edit_playlist',
                  child: Row(
                    children: [
                      const Icon(Icons.edit, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('edit_playlist'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'add_songs',
                  child: Row(
                    children: [
                      const Icon(Icons.add, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('add_songs'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'sort_title',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.sort_by_alpha,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('sort_by_title'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'sort_artist',
                  child: Row(
                    children: [
                      const Icon(Icons.person, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('sort_by_artist'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'sort_date',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.access_time,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        LanguageService().getText('sort_by_date'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Stack(
        children: [
          // Background con color plano - máximo rendimiento
          Container(color: backgroundColor),

          // Content
          CustomScrollView(
            controller: _scrollController,
            cacheExtent: 1500, // Reduced for better memory usage
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // Header con portada, título, descripción y botones
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
                    child: Column(
                      children: [
                        // Portada 1:1 con animación de tamaño
                        Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            width: 300 * _imageScale,
                            height: 300 * _imageScale,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 30,
                                  offset: const Offset(0, 15),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: coverImage != null
                                  ? Image(image: coverImage, fit: BoxFit.cover)
                                  : Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            backgroundColor,
                                            backgroundColor.withOpacity(0.7),
                                          ],
                                        ),
                                      ),
                                      child: Icon(
                                        widget.playlist.id ==
                                                'favorites_virtual'
                                            ? Icons.favorite
                                            : Icons.music_note,
                                        size: 100 * _imageScale,
                                        color: Colors.white.withOpacity(0.5),
                                      ),
                                    ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 32),

                        // Título
                        Text(
                          playlist.name,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const SizedBox(height: 12),

                        // Descripción
                        if (playlist.description != null &&
                            playlist.description!.isNotEmpty)
                          Text(
                            playlist.description!,
                            style: TextStyle(
                              color: textColor.withOpacity(0.7),
                              fontSize: 15,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),

                        const SizedBox(height: 16),

                        // Cantidad de canciones y duración
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.music_note,
                              size: 16,
                              color: textColor.withOpacity(0.6),
                            ),
                            const SizedBox(width: 6),
                            FutureBuilder<Duration>(
                              future: _getTotalDurationFromCache(),
                              builder: (context, snapshot) {
                                final duration = snapshot.data ?? Duration.zero;
                                return Text(
                                  duration.inSeconds > 0
                                      ? '${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')} · ${TextUtils.formatDurationLong(duration)}'
                                      : '${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')}',
                                  style: TextStyle(
                                    color: textColor.withOpacity(0.6),
                                    fontSize: 14,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),

                        const SizedBox(height: 32),

                        // Botones
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Botón Play
                            _buildActionButton(
                              icon: Icons.play_arrow,
                              label: LanguageService().getText('play'),
                              isPrimary: true,
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      _audioPlayer.loadPlaylist(
                                        songs,
                                        initialIndex: 0,
                                        autoPlay: true,
                                      );
                                      Navigator.of(context).push(
                                        PageRouteBuilder(
                                          pageBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                              ) => const MusicPlayerScreen(),
                                          transitionsBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                                child,
                                              ) {
                                                var tween =
                                                    Tween(
                                                      begin: const Offset(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                      end: Offset.zero,
                                                    ).chain(
                                                      CurveTween(
                                                        curve:
                                                            Curves.easeOutCubic,
                                                      ),
                                                    );
                                                return SlideTransition(
                                                  position: animation.drive(
                                                    tween,
                                                  ),
                                                  child: child,
                                                );
                                              },
                                        ),
                                      );
                                    },
                            ),

                            const SizedBox(width: 12),

                            // Botón Shuffle
                            _buildActionButton(
                              icon: Icons.shuffle,
                              label: LanguageService().getText('shuffle'),
                              isPrimary: false,
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      _audioPlayer.toggleShuffle();
                                      _audioPlayer.loadPlaylist(
                                        songs,
                                        initialIndex: 0,
                                        autoPlay: true,
                                      );
                                      Navigator.of(context).push(
                                        PageRouteBuilder(
                                          pageBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                              ) => const MusicPlayerScreen(),
                                          transitionsBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                                child,
                                              ) {
                                                var tween =
                                                    Tween(
                                                      begin: const Offset(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                      end: Offset.zero,
                                                    ).chain(
                                                      CurveTween(
                                                        curve:
                                                            Curves.easeOutCubic,
                                                      ),
                                                    );
                                                return SlideTransition(
                                                  position: animation.drive(
                                                    tween,
                                                  ),
                                                  child: child,
                                                );
                                              },
                                        ),
                                      );
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Lista de canciones con StreamBuilder para actualizar el estado
              if (songs.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      LanguageService().getText('playlist_empty'),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 16,
                      ),
                    ),
                  ),
                )
              else
                // Optimized: No StreamBuilder - same pattern as LocalMusicScreen
                Builder(
                  builder: (context) {
                    final filteredSongs = _getFilteredSongs(songs);
                    return SliverPadding(
                      padding: const EdgeInsets.only(bottom: 100),
                      sliver: SliverFixedExtentList(
                        itemExtent: 72.0, // Fixed height for performance
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index < 0 || index >= filteredSongs.length) {
                              return const SizedBox.shrink();
                            }

                            final song = filteredSongs[index];
                            final isPlaying =
                                _audioPlayer.currentSong?.id == song.id;

                            // Wrap in RepaintBoundary for better isolation
                            return RepaintBoundary(
                              child: Dismissible(
                                key: Key("${song.id}_${playlist.id}"),
                                direction: DismissDirection.endToStart,
                                confirmDismiss: (direction) async {
                                  // Show confirmation to avoid accidental deletes
                                  return await showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: Colors.grey[900],
                                      title: const Text(
                                        'Remove Song',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: Text(
                                        'Remove "${song.title}" from this playlist?',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text(
                                            'Remove',
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                background: Container(
                                  color: Colors.red.withOpacity(0.8),
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                ),
                                onDismissed: (direction) => _removeSong(song),
                                child: LazyMusicTile(
                                  key: ValueKey(song.id),
                                  song: song,
                                  isPlaying: isPlaying,
                                  onTap: () {
                                    _audioPlayer.loadPlaylist(
                                      songs,
                                      initialIndex: songs.indexOf(song),
                                      autoPlay: true,
                                    );
                                    Navigator.of(context).push(
                                      PageRouteBuilder(
                                        pageBuilder:
                                            (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                            ) => const MusicPlayerScreen(),
                                        transitionsBuilder:
                                            (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                              child,
                                            ) {
                                              return SlideTransition(
                                                position:
                                                    Tween(
                                                      begin: const Offset(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                      end: Offset.zero,
                                                    ).animate(
                                                      CurvedAnimation(
                                                        parent: animation,
                                                        curve:
                                                            Curves.easeOutCubic,
                                                      ),
                                                    ),
                                                child: child,
                                              );
                                            },
                                      ),
                                    );
                                  },
                                  onLongPress: () {
                                    SongOptionsBottomSheet.show(
                                      context: context,
                                      song: song,
                                      options: [SongOption.removeFromPlaylist],
                                      onRemove: () => _removeSong(song),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                          childCount: filteredSongs.length,
                          addRepaintBoundaries:
                              false, // We're adding them manually
                          addAutomaticKeepAlives:
                              false, // Disable for better performance
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),

          // Mini Player
          const Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: SafeArea(child: MiniPlayer()),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required bool isPrimary,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: isPrimary
              ? Colors.white
              : Colors.white.withOpacity(0.2),
          foregroundColor: isPrimary ? Colors.black : Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          elevation: isPrimary ? 4 : 0,
        ),
      ),
    );
  }
}
