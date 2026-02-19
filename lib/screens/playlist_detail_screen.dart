import 'package:flutter/material.dart';
import 'dart:io';

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
import '../widgets/playlist_form_sheet.dart';
import '../widgets/add_songs_sheet.dart';
import '../services/metadata_service.dart';

import '../utils/id_generator.dart';

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
  Future<Duration>?
  _durationFuture; // cacheado para no recrearse en cada rebuild

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
    // Create a mutable copy to allow sorting/removing
    _virtualSongs = List.from(widget.playlist.songs);
    _lastImagePath = widget.playlist.imagePath; // Initialize with current image
    PlaylistService().addListener(_onPlaylistChanged);
    MetadataService.onMetadataUpdated.addListener(_onMetadataUpdated);
    _loadCachedColorOrExtract();
    // _durationFuture se inicializa tras el preload (ver _preloadAndComputeDuration)

    // Inicializar animación de búsqueda
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Preload metadata for smoother scrolling, then compute total duration
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadAndComputeDuration();
    });
  }

  Future<void> _preloadMetadata() async {
    // Preload first 50 items or all if small playlist
    final count = _virtualSongs.length > 50 ? 50 : _virtualSongs.length;
    final requests = _virtualSongs.take(count).map((song) {
      return MetadataLoadRequest(
        id: IdGenerator.generateSongId(song.filePath),
        filePath: song.filePath.startsWith('content://') ? null : song.filePath,
        safUri: song.filePath.startsWith('content://') ? song.filePath : null,
        priority: MetadataPriority
            .low, // Low so it doesn't block High priority load from visible tiles
      );
    }).toList();

    await MetadataService().preloadMetadata(requests);
  }

  /// Precarga metadatos y luego calcula la duración total (el orden importa)
  Future<void> _preloadAndComputeDuration() async {
    await _preloadMetadata();
    if (mounted) {
      setState(() {
        _durationFuture = _getTotalDurationFromCache();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();

    _searchController.dispose();
    _animationController.dispose();
    PlaylistService().removeListener(_onPlaylistChanged);
    MetadataService.onMetadataUpdated.removeListener(_onMetadataUpdated);
    super.dispose();
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
      setState(() {
        _durationFuture = _getTotalDurationFromCache();
      });
    }
  }

  void _onMetadataUpdated() {
    if (mounted) {
      // Rebuild to update duration and song details
      setState(() {
        _durationFuture = _getTotalDurationFromCache();
      });
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
          // Use ResizeImage to optimize memory and speed
          imageProvider = ResizeImage(
            FileImage(File(currentPlaylist.imagePath!)),
            width: 20, // Reduced size for color extraction is sufficient
            height: 20,
          );
        } else {
          imageProvider = ResizeImage(
            NetworkImage(currentPlaylist.imagePath!),
            width: 20,
            height: 20,
          );
        }
      }

      if (imageProvider != null) {
        final PaletteGenerator paletteGenerator =
            await PaletteGenerator.fromImageProvider(
              imageProvider,
              size: const Size(20, 20), // Matching the resized image
              maximumColorCount: 16, // Reduced count
            );

        final extractedColor =
            paletteGenerator.dominantColor?.color ??
            paletteGenerator.vibrantColor?.color ??
            paletteGenerator.mutedColor?.color ??
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
      PlaylistService().toggleLike(song);
      setState(() {
        _virtualSongs = List.from(_virtualSongs)
          ..removeWhere((s) => s.id == song.id);
        _durationFuture = _getTotalDurationFromCache();
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
          song.artist.toLowerCase().contains(query) ||
          (song.album?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  Widget _buildSearchField(Color textColor, Color accentColor) {
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
                // Fondo con el color de acento (botones) pero con opacidad ligera
                // para mantener legibilidad y consistencia
                fillColor: accentColor.withOpacity(0.2),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    24,
                  ), // Redondeado como botones
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
    await PlaylistFormSheet.show(
      context,
      playlistToEdit: playlist,
      backgroundColor: _getBottomSheetColor(),
      accentColor: _getAccentColor(),
    );
    if (mounted) {
      await _extractDominantColor();
    }
  }

  Future<void> _showAddSongsDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    return AddSongsSheet.show(
      context,
      playlist: playlist,
      backgroundColor: _getBottomSheetColor(),
      accentColor: _getAccentColor(),
    );
  }

  Color _getBottomSheetColor() {
    final isFavorites = widget.playlist.id == 'favorites_virtual';
    final rawColor = isFavorites
        ? Colors.purpleAccent
        : (_dominantColor ?? Colors.purpleAccent);

    // Asegurar que el color sea notorio, misma lógica que MusicPlayerScreen
    final hsl = HSLColor.fromColor(rawColor);
    final color = hsl.lightness < 0.3
        ? hsl.withLightness(0.6).toColor()
        : rawColor;

    return Color.lerp(const Color(0xFF1C1C1E), color, 0.15) ??
        const Color(0xFF1C1C1E);
  }

  Color _getAccentColor() {
    final isFavorites = widget.playlist.id == 'favorites_virtual';
    final rawColor = isFavorites
        ? Colors.purpleAccent
        : (_dominantColor ?? Colors.purpleAccent);
    final hsl = HSLColor.fromColor(rawColor);

    // Ensure the color is bright enough for dark background bottom sheets
    if (hsl.lightness < 0.5) {
      return hsl.withLightness(0.6).toColor();
    }
    return rawColor;
  }

  void _showPlaylistOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color: _getBottomSheetColor(),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.only(top: 16, bottom: 24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  LanguageService().getText('options'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Divider(color: Colors.white10),
              ),

              // Actions
              _buildOptionItem(
                icon: Icons.shuffle,
                title: LanguageService().getText('shuffle'),
                onTap: () {
                  Navigator.pop(context);
                  final songs = _currentPlaylist.songs;
                  if (songs.isNotEmpty) {
                    _audioPlayer.toggleShuffle();
                    _audioPlayer.loadPlaylist(
                      songs,
                      initialIndex: 0,
                      autoPlay: true,
                    );
                    // Don't auto-open player
                    // Navigator.of(context).push(
                    //   PageRouteBuilder(
                    //     pageBuilder: (context, animation, secondaryAnimation) =>
                    //         const MusicPlayerScreen(),
                    //     transitionsBuilder:
                    //         (context, animation, secondaryAnimation, child) {
                    //           var tween = Tween(
                    //             begin: const Offset(0.0, 1.0),
                    //             end: Offset.zero,
                    //           ).chain(CurveTween(curve: Curves.easeOutCubic));
                    //           return SlideTransition(
                    //             position: animation.drive(tween),
                    //             child: child,
                    //           );
                    //         },
                    //   ),
                    // );
                  }
                },
              ),

              if (widget.playlist.id != 'favorites_virtual')
                _buildOptionItem(
                  icon: Icons.edit,
                  title: LanguageService().getText('edit_playlist'),
                  onTap: () {
                    Navigator.pop(context);
                    _showEditPlaylistDialog(context, _currentPlaylist);
                  },
                ),

              _buildOptionItem(
                icon: Icons.add,
                title: LanguageService().getText('add_songs'),
                onTap: () {
                  Navigator.pop(context);
                  _showAddSongsDialog(context, _currentPlaylist);
                },
              ),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Divider(color: Colors.white10),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Text(
                  LanguageService().getText('information'),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              _buildOptionItem(
                icon: Icons.sort_by_alpha,
                title: LanguageService().getText('sort_by_title'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _virtualSongs.sort(
                      (a, b) => a.title.toLowerCase().compareTo(
                        b.title.toLowerCase(),
                      ),
                    );
                  });
                },
              ),

              _buildOptionItem(
                icon: Icons.person,
                title: LanguageService().getText('sort_by_artist'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _virtualSongs.sort(
                      (a, b) => a.artist.toLowerCase().compareTo(
                        b.artist.toLowerCase(),
                      ),
                    );
                  });
                },
              ),

              _buildOptionItem(
                icon: Icons.access_time,
                title: LanguageService().getText('sort_by_date'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    // Restaurar orden original
                    if (widget.playlist.id == 'favorites_virtual') {
                      // Reload from service source for favorites
                      // Actually for normal playlists we should reload from DB or service
                      // For simplicity, we just trigger a rebuild which might not reset order if _virtualSongs was manipulated in place
                      // But for Favorites virtual logic:
                      _virtualSongs = List.from(widget.playlist.songs);
                    } else {
                      // For normal playlists, _virtualSongs is initialized from widget.playlist.song
                      // If we mutated _virtualSongs, we need to restore.
                      // Best way is to fetch fresh from service
                      final fresh = PlaylistService().playlists.firstWhere(
                        (p) => p.id == widget.playlist.id,
                        orElse: () => widget.playlist,
                      );
                      _virtualSongs = List.from(fresh.songs);
                    }
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptionItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
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
        coverImage = ResizeImage(
          FileImage(File(playlist.imagePath!)),
          width: 300 * MediaQuery.of(context).devicePixelRatio.toInt(),
        );
      } else {
        coverImage = NetworkImage(playlist.imagePath!);
      }
    }

    // Detectar si es favoritos
    final isFavorites = widget.playlist.id == 'favorites_virtual';

    // 1. Background Logic
    final screenBackgroundColor = isFavorites
        ? Colors.black
        : (_dominantColor ?? Colors.black);

    // 2. Button Color Logic
    Color buttonColor;
    Color buttonTextColor;

    if (isFavorites) {
      // Favoritos: Play Morado, Texto Blanco
      buttonColor = Colors.purpleAccent;
      buttonTextColor = Colors.white;
    } else {
      // Otras: Color dominante con ajuste de contraste
      final baseColor = _dominantColor ?? Colors.grey[900]!;
      final hsl = HSLColor.fromColor(baseColor);

      if (hsl.lightness > 0.5) {
        // Fondo Claro -> Botón Oscuro
        buttonColor = hsl.withLightness(0.2).withSaturation(0.8).toColor();
        buttonTextColor = Colors.white;
      } else {
        // Fondo Oscuro -> Botón Claro
        buttonColor = hsl.withLightness(0.8).withSaturation(0.8).toColor();
        buttonTextColor = Colors.black;
      }
    }

    // Antiguo textColor para textos generales (blanco/negro según fondo)
    final textColor = _getTextColor(screenBackgroundColor);

    return Scaffold(
      backgroundColor: screenBackgroundColor,
      body: Stack(
        children: [
          // Fondo de color dominante que cubre TODO el área
          Positioned.fill(child: Container(color: screenBackgroundColor)),

          // ── TODO el contenido en UN SOLO scroll ──
          CustomScrollView(
            controller: _scrollController,
            cacheExtent: 1500,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── PORTADA: zoom nativo en overscroll ──
              SliverAppBar(
                expandedHeight: MediaQuery.of(context).size.width,
                pinned: false,
                floating: false,
                snap: false,
                stretch: true,
                stretchTriggerOffset: 60,
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  stretchModes: const [
                    StretchMode.zoomBackground,
                    StretchMode.blurBackground,
                  ],
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Imagen de portada
                      Builder(
                        builder: (context) {
                          if (widget.playlist.id == 'favorites_virtual') {
                            return Container(
                              color: Colors.grey[900],
                              child: const Center(
                                child: Icon(
                                  Icons.favorite,
                                  color: Colors.purpleAccent,
                                  size: 150,
                                ),
                              ),
                            );
                          }
                          if (coverImage != null) {
                            return Image(image: coverImage, fit: BoxFit.cover);
                          }
                          if (playlist.imagePath == null && songs.isNotEmpty) {
                            final firstArt = songs.first.artworkPath;
                            if (firstArt != null &&
                                File(firstArt).existsSync()) {
                              return Image.file(
                                File(firstArt),
                                fit: BoxFit.cover,
                              );
                            }
                          }
                          return Container(
                            color: Colors.grey[900],
                            child: const Center(
                              child: Icon(
                                Icons.music_note,
                                color: Colors.white10,
                                size: 150,
                              ),
                            ),
                          );
                        },
                      ),

                      // Gradiente: transparente arriba → color dominante abajo
                      // El color final == fondo del bloque de info → sin costura
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.2),
                              Colors.transparent,
                              screenBackgroundColor.withOpacity(0.75),
                              screenBackgroundColor,
                            ],
                            stops: const [0.0, 0.38, 0.78, 1.0],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── INFO: titulo, descripcion, botones ──
              SliverToBoxAdapter(
                child: Container(
                  color: screenBackgroundColor,
                  // Padding ajustado: 16 arriba para separar título
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    children: [
                      Text(
                        playlist.name,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      // Espacio reducido título-descripción
                      const SizedBox(height: 6),

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

                      // Espacio reducido descripción-info
                      const SizedBox(height: 8),

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
                            future: _durationFuture,
                            builder: (context, snapshot) {
                              final duration = snapshot.data ?? Duration.zero;
                              return Text(
                                duration.inSeconds > 0
                                    ? "${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')} · ${TextUtils.formatDurationLong(duration)}"
                                    : "${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')}",
                                style: TextStyle(
                                  color: textColor.withOpacity(0.6),
                                  fontSize: 14,
                                ),
                              );
                            },
                          ),
                        ],
                      ),

                      // Espacio reducido info-botones
                      const SizedBox(height: 20),

                      if (isFavorites)
                        // FAVORITOS: Play y Shuffle ambos tipo Píldora
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Play Button (Primary Pill)
                            _buildPrimaryPlayButton(
                              label: LanguageService().getText('play'),
                              backgroundColor: buttonColor,
                              foregroundColor: buttonTextColor,
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      _audioPlayer.loadPlaylist(
                                        songs,
                                        initialIndex: 0,
                                        autoPlay: true,
                                      );
                                    },
                            ),

                            const SizedBox(width: 16),

                            // Shuffle Button (Secondary Pill - Transparent with Border)
                            SizedBox(
                              height: 44,
                              width: 130,
                              child: OutlinedButton.icon(
                                onPressed: songs.isEmpty
                                    ? null
                                    : () {
                                        _audioPlayer.toggleShuffle();
                                        _audioPlayer.loadPlaylist(
                                          songs,
                                          initialIndex: 0,
                                          autoPlay: true,
                                        );
                                      },
                                icon: Icon(
                                  Icons.shuffle,
                                  size: 20,
                                  color:
                                      buttonColor, // Mismo color que botón play
                                ),
                                label: Text(
                                  LanguageService()
                                      .getText('shuffle')
                                      .toUpperCase(),
                                  style: TextStyle(
                                    color: buttonColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  // Fondo semitransparente como pidió el usuario("misma transparencia que ya tiene")
                                  // Asumo que se refiere a mantener un look sutil
                                  backgroundColor: buttonColor.withOpacity(
                                    0.15,
                                  ),
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        // OTRAS PLAYLISTS: Play (Pill) + Shuffle (Circle) + Add (Circle)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 2. Play Button (Primary Pill)
                            _buildPrimaryPlayButton(
                              label: LanguageService().getText('play'),
                              backgroundColor: buttonColor,
                              foregroundColor: buttonTextColor,
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      _audioPlayer.loadPlaylist(
                                        songs,
                                        initialIndex: 0,
                                        autoPlay: true,
                                      );
                                    },
                            ),

                            const SizedBox(width: 12),

                            // 1. Shuffle Button (Circular)
                            _buildCircularButton(
                              icon: Icons.shuffle,
                              color:
                                  buttonColor, // Color calculado por contraste
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      _audioPlayer.toggleShuffle();
                                      _audioPlayer.loadPlaylist(
                                        songs,
                                        initialIndex: 0,
                                        autoPlay: true,
                                      );
                                    },
                            ),

                            const SizedBox(width: 12),

                            // 3. Add Button (Circular)
                            _buildCircularButton(
                              icon: Icons.add,
                              color: buttonColor,
                              onPressed: () {
                                _showAddSongsDialog(context, _currentPlaylist);
                              },
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),

              // ── LISTA DE CANCIONES ──
              if (songs.isEmpty)
                SliverFillRemaining(
                  child: Container(
                    color: screenBackgroundColor,
                    child: Center(
                      child: Text(
                        LanguageService().getText('playlist_empty'),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                )
              else
                StreamBuilder<Song?>(
                  stream: _audioPlayer.currentSongStream,
                  builder: (context, songSnapshot) {
                    final currentSong = songSnapshot.data;
                    final filteredSongs = _getFilteredSongs(songs);
                    return SliverPadding(
                      padding: const EdgeInsets.only(bottom: 100),
                      sliver: SliverFixedExtentList(
                        itemExtent: 72.0,
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index < 0 || index >= filteredSongs.length) {
                              return const SizedBox.shrink();
                            }
                            final song = filteredSongs[index];
                            final isPlaying = currentSong?.id == song.id;

                            return RepaintBoundary(
                              child: Dismissible(
                                key: Key("${song.id}_${playlist.id}"),
                                direction: DismissDirection.endToStart,
                                confirmDismiss: (direction) async {
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
                                  },
                                  onLongPress: () {
                                    SongOptionsBottomSheet.show(
                                      context: context,
                                      song: song,
                                      options: [SongOption.removeFromPlaylist],
                                      onRemove: () => _removeSong(song),
                                      backgroundColor: _getBottomSheetColor(),
                                      accentColor: _getAccentColor(),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                          childCount: filteredSongs.length,
                          addRepaintBoundaries: false,
                          addAutomaticKeepAlives: false,
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),

          // ── AppBar flotante transparente (siempre visible) ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ), // Padding aumentado
                child: Row(
                  children: [
                    _buildCircularButton(
                      icon: Icons.arrow_back,
                      color: buttonColor,
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: _isSearching
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal:
                                      12, // Más espacio alrededor del buscador
                                ),
                                child: _buildSearchField(
                                  textColor, // Texto (contraste con pantalla)
                                  buttonColor, // Fondo (acento de la playlist)
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('empty')),
                      ),
                    ),

                    // Separación Search Button -> More Button si NO está buscando (o search está a la derecha)
                    // Si está buscando, search button es 'X'.
                    // Si no está buscando, es Lupa.
                    if (!_isSearching)
                      const Spacer(), // Empujar iconos a la derecha si no hay buscador expandido

                    _buildCircularButton(
                      icon: _isSearching ? Icons.close : Icons.search,
                      color: buttonColor,
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

                    if (!_isSearching) ...[
                      const SizedBox(
                        width: 12,
                      ), // Separación entre Lupa y Opciones
                      _buildCircularButton(
                        icon: Icons.more_horiz,
                        color: buttonColor,
                        onPressed: () => _showPlaylistOptions(context),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // ── Mini Player ──
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

  Widget _buildCircularButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    // Reducir tamaño de 56 a 44 y eliminar borde
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15), // Fondo un poco más visible sin borde
        shape: BoxShape.circle,
        // Borde eliminado para look más limpio
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 22),
        onPressed: onPressed,
        tooltip: 'Action',
        padding: EdgeInsets
            .zero, // Remove padding to center icon better in smaller space
      ),
    );
  }

  Widget _buildPrimaryPlayButton({
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required VoidCallback? onPressed,
  }) {
    // Reducir altura a 44 y ancho
    return SizedBox(
      height: 44,
      width: 130,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(Icons.play_arrow, size: 24, color: foregroundColor),
        label: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: foregroundColor,
            fontWeight: FontWeight.bold,
            fontSize: 14, // Fuente más pequeña
            letterSpacing: 1.0,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          elevation: 2, // Menos elevación
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22), // Radio ajustado
          ),
        ),
      ),
    );
  }
}
