import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import '../services/playlist_service.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../widgets/lazy_music_tile.dart';
import '../widgets/mini_player.dart';
import '../services/music_metadata_cache.dart';
import 'music_player_screen.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final ScrollController _scrollController = ScrollController();
  Color? _dominantColor;
  double _imageScale = 1.0;

  // Estado local para manejar favoritos (que no están en PlaylistService._playlists)
  late List<Song> _virtualSongs;
  List<Song> _songsWithDuration = [];

  @override
  void initState() {
    super.initState();
    _virtualSongs = widget.playlist.songs;
    PlaylistService().addListener(_onPlaylistChanged);
    _loadCachedColorOrExtract();
    _scrollController.addListener(_onScroll);
    _loadSongDurations();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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
    if (mounted) setState(() {});
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

  Future<void> _loadSongDurations() async {
    final updatedSongs = <Song>[];

    for (var song in _currentPlaylist.songs) {
      // Intentar cargar desde caché
      final cachedMetadata = await MusicMetadataCache.get(song.id);

      if (cachedMetadata != null && cachedMetadata.durationMs != null) {
        // Tiene duración en caché
        updatedSongs.add(
          song.copyWith(
            duration: Duration(milliseconds: cachedMetadata.durationMs!),
          ),
        );
      } else {
        // No tiene duración, usar la canción original
        updatedSongs.add(song);
      }
    }

    if (mounted) {
      setState(() {
        _songsWithDuration = updatedSongs;
      });
    }
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

      if (widget.playlist.imagePath != null) {
        if (File(widget.playlist.imagePath!).existsSync()) {
          imageProvider = FileImage(File(widget.playlist.imagePath!));
        } else {
          imageProvider = NetworkImage(widget.playlist.imagePath!);
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

        // Guardar en caché
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'playlist_color_${widget.playlist.id}';
        await prefs.setInt(cacheKey, extractedColor.value);

        if (mounted) {
          setState(() {
            _dominantColor = extractedColor;
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

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '$hours h $minutes min';
    } else {
      return '$minutes min';
    }
  }

  Duration _getTotalDuration() {
    // Usar canciones con duración cargada si están disponibles
    final songsToCheck = _songsWithDuration.isNotEmpty
        ? _songsWithDuration
        : _currentPlaylist.songs;

    int totalMs = 0;
    int songsWithDuration = 0;
    for (var song in songsToCheck) {
      if (song.duration != null) {
        totalMs += song.duration!.inMilliseconds;
        songsWithDuration++;
      }
    }
    print(
      '[PlaylistDetail] Total songs: ${songsToCheck.length}, Songs with duration: $songsWithDuration, Total duration: ${Duration(milliseconds: totalMs)}',
    );
    return Duration(milliseconds: totalMs);
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

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;
    final songs = playlist.songs;
    final totalDuration = _getTotalDuration();

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

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // Background con color dominante
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  backgroundColor.withOpacity(0.8),
                  backgroundColor.withOpacity(0.4),
                  Colors.black,
                ],
              ),
            ),
          ),

          // Blur effect
          if (coverImage != null)
            Positioned.fill(
              child: Image(
                image: coverImage,
                fit: BoxFit.cover,
                opacity: const AlwaysStoppedAnimation(0.15),
              ),
            ),

          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
            child: Container(color: Colors.black.withOpacity(0.3)),
          ),

          // Content
          CustomScrollView(
            controller: _scrollController,
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
                          style: const TextStyle(
                            color: Colors.white,
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
                              color: Colors.white.withOpacity(0.7),
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
                              color: Colors.white.withOpacity(0.6),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              totalDuration.inSeconds > 0
                                  ? '${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')} · ${_formatDuration(totalDuration)}'
                                  : '${songs.length} ${songs.length == 1 ? LanguageService().getText('song') : LanguageService().getText('songs')}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 14,
                              ),
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
                StreamBuilder<Song?>(
                  stream: _audioPlayer.currentSongStream,
                  builder: (context, snapshot) {
                    final currentSong = snapshot.data;

                    return SliverPadding(
                      padding: const EdgeInsets.only(bottom: 100),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final song = songs[index];
                          final isPlaying = currentSong?.id == song.id;

                          return Dismissible(
                            key: Key("${song.id}_${playlist.id}"),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Colors.red,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
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
                                  initialIndex: index,
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
                                                begin: const Offset(0.0, 1.0),
                                                end: Offset.zero,
                                              ).chain(
                                                CurveTween(
                                                  curve: Curves.easeOutCubic,
                                                ),
                                              );
                                          return SlideTransition(
                                            position: animation.drive(tween),
                                            child: child,
                                          );
                                        },
                                  ),
                                );
                              },
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  backgroundColor: Colors.grey[900],
                                  builder: (ctx) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: const Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                          ),
                                          title: Text(
                                            LanguageService().getText(
                                              'remove_from_playlist',
                                            ),
                                            style: const TextStyle(
                                              color: Colors.red,
                                            ),
                                          ),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _removeSong(song);
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        }, childCount: songs.length),
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
