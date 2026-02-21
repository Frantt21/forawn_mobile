import 'package:text_scroll/text_scroll.dart'; // Added
import 'dart:ui';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../services/playlist_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart' as player_state;
import '../widgets/lyrics_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/lyrics_service.dart';
import 'package:audiotags/audiotags.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/deezer_service.dart';
import '../services/foranly_service.dart';
import '../services/metadata_service.dart';
import '../services/saf_helper.dart';
import '../services/music_library_service.dart';
import '../services/music_metadata_cache.dart';
import 'dart:typed_data';
import '../widgets/artwork_widget.dart'; // Added

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final AudioPlayerService _player = AudioPlayerService();
  String? _lastSongId;
  bool _isNextDirection = true;
  bool _showHeartAnimation = false;
  bool _isDragging = false;
  double _dragValue = 0.0;

  void _skipToNext() {
    setState(() {
      _isNextDirection = true;
    });
    _player.skipToNext();
  }

  void _skipToPrevious() {
    setState(() {
      _isNextDirection = false;
    });
    _player.skipToPrevious();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Song?>(
        stream: _player.currentSongStream,
        builder: (context, snapshot) {
          final song = snapshot.data;

          if (song == null) {
            return Container(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            );
          }

          return Stack(
            children: [
              _buildBackground(song),
              SafeArea(
                child: Column(
                  children: [
                    _buildHeader(context, song),
                    Flexible(
                      fit: FlexFit.loose,
                      child: GestureDetector(
                        onHorizontalDragEnd: (details) {
                          if (details.primaryVelocity! < 0) {
                            _skipToNext();
                          } else if (details.primaryVelocity! > 0) {
                            _skipToPrevious();
                          }
                        },
                        onVerticalDragEnd: (details) {
                          if (details.primaryVelocity! > 500) {
                            Navigator.of(context).pop();
                          }
                        },
                        onDoubleTap: () {
                          PlaylistService().toggleLike(song);
                          setState(() {
                            _showHeartAnimation = true;
                          });
                          Future.delayed(const Duration(milliseconds: 800), () {
                            if (mounted) {
                              setState(() {
                                _showHeartAnimation = false;
                              });
                            }
                          });
                        },
                        child: _buildArtwork(song),
                      ),
                    ),
                    _buildControls(song),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
              // Draggable Lyrics Sheet
              DraggableScrollableSheet(
                initialChildSize: 0.11,
                minChildSize: 0.11,
                maxChildSize: 0.9,
                snap: true,
                snapSizes: const [0.11, 0.9],
                builder: (context, scrollController) {
                  return SingleChildScrollView(
                    controller: scrollController,
                    physics: const ClampingScrollPhysics(),
                    child: SizedBox(
                      height: MediaQuery.of(context).size.height * 0.9,
                      child: LyricsSheet(
                        song: song,
                        player: _player,
                        onTapHeader: () {},
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBackground(Song song) {
    final backgroundColor = song.dominantColor != null
        ? Color(song.dominantColor!)
        : Colors.grey[900]!;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [backgroundColor, Colors.black],
        ),
      ),
    );
  }

  Color _getDominantColor(Song song) {
    if (song.dominantColor != null) {
      return Color(song.dominantColor!);
    }
    return Colors.purpleAccent;
  }

  Widget _buildHeader(BuildContext context, Song song) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! > 0) {
          Navigator.of(context).pop();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white,
                size: 32,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Text(
              LanguageService().getText('now_playing').toUpperCase(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: () => _showOptionsSheet(context, song),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(Song song) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 24.0,
        right: 24.0,
        top: 18.0,
        bottom: 48.0,
      ),
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 300.0;

            return Hero(
              tag: 'artwork_${song.id}',
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                              final offsetRight = const Offset(1.0, 0.0);
                              final offsetLeft = const Offset(-1.0, 0.0);
                              final inTween = _isNextDirection
                                  ? Tween<Offset>(
                                      begin: offsetRight,
                                      end: Offset.zero,
                                    )
                                  : Tween<Offset>(
                                      begin: offsetLeft,
                                      end: Offset.zero,
                                    );
                              final outTween = _isNextDirection
                                  ? Tween<Offset>(
                                      begin: offsetLeft,
                                      end: Offset.zero,
                                    )
                                  : Tween<Offset>(
                                      begin: offsetRight,
                                      end: Offset.zero,
                                    );
                              final inAnimation = inTween.animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutQuad,
                                ),
                              );
                              final outAnimation = outTween.animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeInQuad,
                                ),
                              );
                              if (child.key == ValueKey(song.id)) {
                                return SlideTransition(
                                  position: inAnimation,
                                  child: child,
                                );
                              } else {
                                return SlideTransition(
                                  position: outAnimation,
                                  child: child,
                                );
                              }
                            },
                        child: ArtworkWidget(
                          key: ValueKey(song.id),
                          artworkPath: song.artworkPath,
                          artworkUri: song.artworkUri,
                          size: size,
                          width: size,
                          height: size,
                          fit: BoxFit.cover,
                          dominantColor: song.dominantColor,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: _showHeartAnimation ? 1.0 : 0.0,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(
                            begin: 0.5,
                            end: _showHeartAnimation ? 1.2 : 0.5,
                          ),
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.elasticOut,
                          builder: (context, scale, child) {
                            // Use the same color logic as controls
                            final rawColor = _getDominantColor(song);
                            final heartColor =
                                HSLColor.fromColor(rawColor).lightness < 0.3
                                ? HSLColor.fromColor(
                                    rawColor,
                                  ).withLightness(0.6).toColor()
                                : rawColor;

                            return Transform.scale(
                              scale: scale,
                              child: Icon(
                                Icons.favorite_rounded,
                                color: heartColor,
                                size: 80,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls(Song song) {
    final rawColor = _getDominantColor(song);
    // Asegurar que el color tenga suficiente brillo para controles sobre fondo oscuro
    final color = HSLColor.fromColor(rawColor).lightness < 0.3
        ? HSLColor.fromColor(rawColor).withLightness(0.6).toColor()
        : rawColor;

    return TweenAnimationBuilder<Color?>(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      tween: ColorTween(begin: color, end: color),
      builder: (context, animatedColor, child) {
        final effectiveColor = animatedColor ?? Colors.purpleAccent;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row: Add to Playlist (Left) - Title/Artist (Center) - Favorite (Right)
              // Stack: Add to Playlist (Left) - Title/Artist (Center) - Favorite (Right)
              // Row: Title/Artist (Left) - Buttons (Right)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Title and Artist (Left Aligned)
                  Flexible(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextScroll(
                          song.title,
                          key: ValueKey('title_${song.id}'),
                          mode: TextScrollMode.endless,
                          velocity: const Velocity(
                            pixelsPerSecond: Offset(30, 0),
                          ),
                          delayBefore: const Duration(seconds: 3),
                          pauseBetween: const Duration(seconds: 3),
                          intervalSpaces: 25,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.left,
                          selectable: false,
                        ),
                        const SizedBox(height: 4),
                        TextScroll(
                          song.artist,
                          key: ValueKey('artist_${song.id}'),
                          mode: TextScrollMode.endless,
                          velocity: const Velocity(
                            pixelsPerSecond: Offset(30, 0),
                          ),
                          delayBefore: const Duration(seconds: 3),
                          pauseBetween: const Duration(seconds: 3),
                          intervalSpaces: 25,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.left,
                          selectable: false,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12), // Space between text and buttons
                  // Buttons (Right Aligned)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Add to Playlist Button
                      GestureDetector(
                        onTap: () {
                          _showAddToPlaylistDialog(context, song);
                        },
                        child: Icon(
                          Icons.playlist_add,
                          color: effectiveColor,
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: 16), // Espacio aumentado
                      // Favorite Button
                      ListenableBuilder(
                        listenable: PlaylistService(),
                        builder: (context, child) {
                          final isLiked = PlaylistService().isLiked(song.id);
                          return GestureDetector(
                            onTap: () {
                              PlaylistService().toggleLike(song);
                            },
                            child: Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              color: isLiked ? effectiveColor : Colors.white,
                              size: 30,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Slider de Progreso
              StreamBuilder<player_state.PlaybackProgress>(
                stream: _player.progressStream,
                builder: (context, snapshot) {
                  final progress =
                      snapshot.data ?? player_state.PlaybackProgress.zero();

                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          trackShape: CustomTrackShape(),
                          thumbShape: TransparentThumbShape(),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 0,
                          ),
                          activeTrackColor: effectiveColor,
                          inactiveTrackColor: effectiveColor.withOpacity(0.3),
                          thumbColor: Colors.transparent,
                          overlayColor: Colors.transparent,
                        ),
                        child: Slider(
                          value:
                              (_isDragging
                                      ? _dragValue
                                      : progress.position.inMilliseconds
                                            .toDouble())
                                  .clamp(
                                    0.0,
                                    progress.duration.inMilliseconds.toDouble(),
                                  ),
                          min: 0.0,
                          max: progress.duration.inMilliseconds.toDouble() > 0
                              ? progress.duration.inMilliseconds.toDouble()
                              : 1.0,
                          onChangeStart: (value) {
                            setState(() {
                              _isDragging = true;
                              _dragValue = value;
                            });
                          },
                          onChanged: (value) {
                            setState(() {
                              _dragValue = value;
                            });
                          },
                          onChangeEnd: (value) {
                            _player.seek(Duration(milliseconds: value.toInt()));
                            setState(() {
                              _isDragging = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(
                        height: 0,
                      ), // Reducido el espacio a petición
                      Padding(
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              progress.formattedPosition,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              progress.formattedDuration,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 10),

              // Botones de Control
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Shuffle Toggle
                  StreamBuilder<bool>(
                    stream: _player.shuffleModeStream,
                    builder: (context, snapshot) {
                      final isShuffle = snapshot.data ?? false;
                      return IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: isShuffle ? effectiveColor : Colors.white,
                        ),
                        onPressed: _player.toggleShuffle,
                      );
                    },
                  ),

                  // Previous
                  IconButton(
                    icon: Icon(
                      Icons.skip_previous_rounded,
                      color: effectiveColor,
                      size: 42,
                    ),
                    onPressed: _skipToPrevious,
                  ),

                  // Play/Pause
                  StreamBuilder<player_state.PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final state =
                          snapshot.data ?? player_state.PlayerState.idle;
                      final isPlaying =
                          state == player_state.PlayerState.playing;
                      final isBuffering =
                          state == player_state.PlayerState.buffering ||
                          state == player_state.PlayerState.loading;

                      return IconButton(
                        iconSize: 72,
                        padding: EdgeInsets.zero,
                        icon: isBuffering
                            ? SizedBox(
                                width: 72,
                                height: 72,
                                child: Center(
                                  child: SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: effectiveColor,
                                    ),
                                  ),
                                ),
                              )
                            : Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 72,
                                color: effectiveColor,
                              ),
                        onPressed: isPlaying ? _player.pause : _player.play,
                      );
                    },
                  ),

                  // Next
                  IconButton(
                    icon: Icon(
                      Icons.skip_next_rounded,
                      color: effectiveColor,
                      size: 42,
                    ),
                    onPressed: _skipToNext,
                  ),

                  // Repeat Mode
                  StreamBuilder<player_state.RepeatMode>(
                    stream: _player.repeatModeStream,
                    builder: (context, snapshot) {
                      final mode = snapshot.data ?? player_state.RepeatMode.off;
                      IconData icon;
                      Color color = Colors.white;

                      switch (mode) {
                        case player_state.RepeatMode.one:
                          icon = Icons.repeat_one_rounded;
                          color = effectiveColor;
                          break;
                        case player_state.RepeatMode.all:
                          icon = Icons.repeat_rounded;
                          color = effectiveColor;
                          break;
                        case player_state.RepeatMode.off:
                          icon = Icons.repeat_rounded;
                          color = Colors.white38;
                          break;
                      }

                      return IconButton(
                        icon: Icon(icon, color: color),
                        onPressed: _player.toggleRepeat,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10), // Reduced spacing
            ],
          ),
        );
      },
    );
  }

  void _showOptionsSheet(BuildContext context, Song song) {
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
            color:
                Color.lerp(
                  const Color(0xFF1C1C1E),
                  song.dominantColor != null
                      ? Color(song.dominantColor!)
                      : Colors.purpleAccent,
                  0.15,
                ) ??
                const Color(0xFF1C1C1E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.only(top: 16),
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
              // Header Song Info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    ArtworkWidget(
                      artworkPath: song.artworkPath,
                      artworkUri: song.artworkUri,
                      width: 56,
                      height: 56,
                      size: 56,
                      borderRadius: BorderRadius.circular(8),
                      dominantColor: song.dominantColor,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Divider(color: Colors.white10),
              ),

              // Options
              ListTile(
                leading: const Icon(Icons.playlist_add, color: Colors.white),
                title: Text(
                  LanguageService().getText('add_to_playlist'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              // Toggle Favorite
              ValueListenableBuilder<List<String>>(
                valueListenable: PlaylistService().favoritesNotifier,
                builder: (context, favorites, _) {
                  final isFavorite = favorites.contains(song.id);
                  return ListTile(
                    leading: Icon(
                      isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: isFavorite ? Colors.redAccent : Colors.white,
                    ),
                    title: Text(
                      isFavorite
                          ? LanguageService().getText('remove_from_favorites')
                          : LanguageService().getText('add_to_favorites'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      PlaylistService().toggleLike(song);
                      // Don't pop immediately so user sees the change state
                      // Navigator.pop(context);
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white),
                title: Text(
                  LanguageService().getText('edit_metadata'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showMetadataSearchDialog(context, song);
                },
              ),
              ListTile(
                leading: const Icon(Icons.search, color: Colors.white),
                title: Text(
                  LanguageService().getText('search_lyrics'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    isScrollControlled: true,
                    builder: (_) => LyricsSearchDialog(
                      initialQuery: '${song.title} ${song.artist}',
                      dominantColor: song.dominantColor,
                      onLyricSelected: (l) {
                        LyricsService().saveLyricsToCache(
                          localTrackName: song.title,
                          localArtistName: song.artist,
                          lyrics: l,
                        );
                        LyricsService().updateLyrics(l);
                      },
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: Text(
                  LanguageService().getText('delete_lyrics'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  final prefs = await SharedPreferences.getInstance();
                  final cacheKey =
                      'lyrics_cache_${'${song.title.toLowerCase()}_${song.artist.toLowerCase()}'.replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';
                  await prefs.remove(cacheKey);
                  LyricsService().clearCurrentLyrics();
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // Mostrar diálogo para agregar a playlist
  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (_, controller) {
            return Container(
              decoration: BoxDecoration(
                color:
                    Color.lerp(
                      const Color(0xFF1C1C1E),
                      song.dominantColor != null
                          ? Color(song.dominantColor!)
                          : Colors.purpleAccent,
                      0.15,
                    ) ??
                    const Color(0xFF1C1C1E),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.all(24),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 24),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Título
                  Text(
                    LanguageService().getText('add_to_playlist'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Botón de nueva playlist
                  InkWell(
                    onTap: () {
                      Navigator.pop(context);
                      // TODO: Mostrar diálogo de crear playlist con la canción
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            LanguageService().getText('feature_coming_soon'),
                          ),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color:
                            (song.dominantColor != null
                                    ? Color(song.dominantColor!)
                                    : Colors.purpleAccent)
                                .withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              (song.dominantColor != null
                                      ? Color(song.dominantColor!)
                                      : Colors.purpleAccent)
                                  .withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color:
                                  (song.dominantColor != null
                                          ? Color(song.dominantColor!)
                                          : Colors.purpleAccent)
                                      .withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.add_circle_outline,
                              color: song.dominantColor != null
                                  ? Color(song.dominantColor!)
                                  : Colors.purpleAccent,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            LanguageService().getText('new_playlist'),
                            style: TextStyle(
                              color: song.dominantColor != null
                                  ? Color(song.dominantColor!)
                                  : Colors.purpleAccent,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Lista de playlists
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: PlaylistService().playlists.map((playlist) {
                          // Verificar si la canción ya está en la playlist
                          final songExists = playlist.songs.any(
                            (s) => s.id == song.id,
                          );

                          return InkWell(
                            onTap: songExists
                                ? null
                                : () async {
                                    await PlaylistService().addSongToPlaylist(
                                      playlist.id,
                                      song,
                                    );
                                    if (mounted) {
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            LanguageService()
                                                .getText('added_to')
                                                .replaceFirst(
                                                  '%s',
                                                  playlist.name,
                                                ),
                                          ),
                                          backgroundColor:
                                              song.dominantColor != null
                                              ? Color(song.dominantColor!)
                                              : Colors.purpleAccent,
                                        ),
                                      );
                                    }
                                  },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: songExists
                                    ? Colors.white.withOpacity(0.03)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  // Imagen de la playlist
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1C1C1E),
                                      borderRadius: BorderRadius.circular(8),
                                      image: playlist.imagePath != null
                                          ? DecorationImage(
                                              image:
                                                  File(
                                                    playlist.imagePath!,
                                                  ).existsSync()
                                                  ? FileImage(
                                                      File(playlist.imagePath!),
                                                    )
                                                  : NetworkImage(
                                                          playlist.imagePath!,
                                                        )
                                                        as ImageProvider,
                                              fit: BoxFit.cover,
                                            )
                                          : null,
                                    ),
                                    child: playlist.imagePath == null
                                        ? const Icon(
                                            Icons.music_note,
                                            color: Colors.white54,
                                            size: 24,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 16),
                                  // Info de la playlist
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          playlist.name,
                                          style: TextStyle(
                                            color: songExists
                                                ? Colors.white54
                                                : Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          "${playlist.songs.length} ${LanguageService().getText('songs')}",
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.5,
                                            ),
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Indicador si ya existe
                                  if (songExists)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.check_circle,
                                            color: Colors.green,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            LanguageService().getText('added'),
                                            style: const TextStyle(
                                              color: Colors.green,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const SizedBox(height: 16),

                  // Botón cerrar
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        LanguageService().getText('cancel'),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
  // --- Metadata Update Feature ---

  void _showMetadataSearchDialog(BuildContext context, Song song) {
    final titleController = TextEditingController(text: song.title);
    final artistController = TextEditingController(text: song.artist);
    bool isLoading = false;
    List<Map<String, dynamic>> searchResults = [];
    String? errorMessage;
    String selectedSource = 'Deezer'; // Default to Deezer

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              builder: (_, controller) {
                return Container(
                  decoration: BoxDecoration(
                    color:
                        Color.lerp(
                          const Color(0xFF1C1C1E),
                          song.dominantColor != null
                              ? Color(song.dominantColor!)
                              : Colors.purpleAccent,
                          0.15,
                        ) ??
                        const Color(0xFF1C1C1E),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 24),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            LanguageService().getText('update_metadata'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white54,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Source Selector
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  selectedSource = 'Deezer';
                                  searchResults = [];
                                  errorMessage = null;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selectedSource == 'Deezer'
                                        ? (song.dominantColor != null
                                              ? Color(
                                                  song.dominantColor!,
                                                ).withOpacity(0.2)
                                              : Colors.purpleAccent.withOpacity(
                                                  0.2,
                                                ))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.horizontal(
                                      left: const Radius.circular(12),
                                      right: Radius.circular(
                                        selectedSource == 'Deezer' ? 12 : 0,
                                      ),
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    LanguageService().getText('deezer_precise'),
                                    style: TextStyle(
                                      color: selectedSource == 'Deezer'
                                          ? (song.dominantColor != null
                                                ? Color(song.dominantColor!)
                                                : Colors.purpleAccent)
                                          : Colors.white70,
                                      fontWeight: selectedSource == 'Deezer'
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  selectedSource = 'Server';
                                  searchResults = [];
                                  errorMessage = null;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selectedSource == 'Server'
                                        ? (song.dominantColor != null
                                              ? Color(
                                                  song.dominantColor!,
                                                ).withOpacity(0.2)
                                              : Colors.purpleAccent.withOpacity(
                                                  0.2,
                                                ))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.horizontal(
                                      right: const Radius.circular(12),
                                      left: Radius.circular(
                                        selectedSource == 'Server' ? 12 : 0,
                                      ),
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    LanguageService().getText(
                                      'spotify_less_precise',
                                    ),
                                    style: TextStyle(
                                      color: selectedSource == 'Server'
                                          ? (song.dominantColor != null
                                                ? Color(song.dominantColor!)
                                                : Colors.purpleAccent)
                                          : Colors.white70,
                                      fontWeight: selectedSource == 'Server'
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: titleController,
                        cursorColor: song.dominantColor != null
                            ? Color(song.dominantColor!)
                            : Colors.purpleAccent,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: LanguageService().getText('song'),
                          hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: artistController,
                        cursorColor: song.dominantColor != null
                            ? Color(song.dominantColor!)
                            : Colors.purpleAccent,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: LanguageService()
                              .getText('playlist_desc')
                              .replaceAll('Descripción', 'Artista'), // Fallback
                          hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        icon: isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.search),
                        label: Text(LanguageService().getText('search')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: song.dominantColor != null
                              ? Color(song.dominantColor!)
                              : Colors.purpleAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: isLoading
                            ? null
                            : () async {
                                setState(() {
                                  isLoading = true;
                                  errorMessage = null;
                                  searchResults = [];
                                });

                                try {
                                  if (selectedSource == 'Deezer') {
                                    final results = await DeezerService()
                                        .searchMetadata(
                                          titleController.text,
                                          artistController.text,
                                        );
                                    setState(() {
                                      isLoading = false;
                                      searchResults = results;
                                      if (results.isEmpty) {
                                        errorMessage = LanguageService()
                                            .getText('no_results');
                                      }
                                    });
                                  } else {
                                    // Server (Foranly)
                                    final result = await ForanlyService()
                                        .searchMetadata(
                                          titleController.text,
                                          artistController.text,
                                        );
                                    setState(() {
                                      isLoading = false;
                                      if (result != null) {
                                        searchResults = [result];
                                      } else {
                                        errorMessage = LanguageService()
                                            .getText('no_results');
                                      }
                                    });
                                  }
                                } catch (e) {
                                  setState(() {
                                    isLoading = false;
                                    errorMessage = 'Error: $e';
                                  });
                                }
                              },
                      ),
                      if (errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(color: Colors.redAccent),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      if (searchResults.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        const Divider(color: Colors.white24),
                        const SizedBox(height: 10),
                        Text(
                          '${LanguageService().getText('results')} (${searchResults.length})',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 10),
                        ...searchResults.map((result) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child:
                                    result['albumArt'] != null &&
                                        result['albumArt']['data'] != null
                                    ? Image.memory(
                                        Uint8List.fromList(
                                          List<int>.from(
                                            result['albumArt']['data'],
                                          ),
                                        ),
                                        width: 50,
                                        height: 50,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => const Icon(
                                          Icons.music_note,
                                          color: Colors.white,
                                        ),
                                      )
                                    : (result['albumArtUrl'] != null
                                          ? Image.network(
                                              result['albumArtUrl'],
                                              width: 50,
                                              height: 50,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  const Icon(
                                                    Icons.music_note,
                                                    color: Colors.white,
                                                  ),
                                            )
                                          : const Icon(
                                              Icons.music_note,
                                              color: Colors.white,
                                              size: 50,
                                            )),
                              ),
                              title: Text(
                                result['title'] ?? 'Unknown',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                "${result['artist'] ?? 'Unknown'} • ${result['album'] ?? ''}",
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.check_circle,
                                  color: Colors.greenAccent,
                                  size: 32,
                                ),
                                onPressed: () {
                                  _applyMetadata(context, song, result);
                                },
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _applyMetadata(
    BuildContext context,
    Song song,
    Map<String, dynamic> metadata,
  ) async {
    // 1. Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.purpleAccent),
      ),
    );

    try {
      // 2. Download artwork if URL provided (and not already bytes)
      List<int>? artworkBytes;

      if (metadata['albumArt'] != null &&
          metadata['albumArt']['data'] != null) {
        artworkBytes = List<int>.from(metadata['albumArt']['data']);
      } else if (metadata['albumArtUrl'] != null) {
        try {
          final resp = await http
              .get(Uri.parse(metadata['albumArtUrl']))
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            artworkBytes = resp.bodyBytes;
          }
        } catch (e) {
          print('Error downloading artwork: $e');
        }
      }

      // 3. Write tags using AudioTags
      String path = song.filePath;
      bool isSaf = path.startsWith('content://');

      if (!isSaf && Platform.isAndroid) {
        // En Android 11+ necesitamos MANAGE_EXTERNAL_STORAGE para escribir en archivos
        // que no pertenecen a la app (escaneados) usando File API directa.
        // Verificamos y pedimos el permiso si no lo tenemos.
        if (await Permission.manageExternalStorage.status.isDenied) {
          final status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            throw Exception(
              "${LanguageService().getText('permission_denied')}: Manage External Storage required",
            );
          }
        }
      }

      File? tempFile;
      String targetPath = path;

      if (isSaf) {
        // Create temp file
        final tempDir = await getTemporaryDirectory();
        final tempName = 'temp_${DateTime.now().millisecondsSinceEpoch}.mp3';
        tempFile = File('${tempDir.path}/$tempName');

        // Copy content from SAF to temp
        final success = await SafHelper.copyUriToFile(path, tempFile.path);
        if (!success) throw Exception("Failed to copy SAF file to temp");

        targetPath = tempFile.path;
      } else {
        if (path.startsWith('file://')) {
          targetPath = path.replaceFirst('file://', '');
        }
        if (!File(targetPath).existsSync()) {
          throw Exception("File not found at $targetPath");
        }
      }

      // Update Tags
      final tag = Tag(
        title: metadata['title'],
        trackArtist: metadata['artist'],
        album: metadata['album'],
        year: int.tryParse(metadata['year']?.toString() ?? ''),
        trackNumber: int.tryParse(metadata['trackNumber']?.toString() ?? ''),
        pictures: artworkBytes != null
            ? [
                Picture(
                  bytes: Uint8List.fromList(artworkBytes),
                  mimeType: MimeType.jpeg,
                  pictureType: PictureType.coverFront,
                ),
              ]
            : [],
      );

      await AudioTags.write(targetPath, tag);

      if (isSaf && tempFile != null) {
        // Write back to SAF
        final success = await SafHelper.overwriteFileFromPath(path, targetPath);
        if (!success) throw Exception("Failed to write back to SAF file");

        // Cleanup
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      // 4. Update Cache & UI
      // CRITICAL: Delete ALL cache layers for this song FIRST
      // FIX: Use stable ID (song.id) instead of unstable hashCode
      final cacheKey = song.id;

      // Delete from persistent cache
      await MusicMetadataCache.delete(cacheKey);

      // Delete from MetadataService memory cache
      MetadataService().clearCacheEntry(cacheKey);

      // Now reload fresh metadata from the file we just modified
      await MetadataService().loadMetadata(
        id: cacheKey,
        filePath: song.filePath.startsWith('content://') ? null : song.filePath,
        safUri: song.filePath.startsWith('content://') ? song.filePath : null,
        forceReload: true,
      );

      // Update Player UI
      await AudioPlayerService().refreshCurrentSongMetadata();

      // Notify Library to update song in list
      // Hack: Reset to null first to ensure ValueNotifier notifies listeners even if the path is the same
      MusicLibraryService.onMetadataUpdated.value = null;
      MusicLibraryService.onMetadataUpdated.value = song.filePath;

      // Force UI refresh in this screen
      if (mounted) {
        setState(() {});
      }

      if (mounted) {
        // Close Loading
        Navigator.of(context).pop();
        // Close Search Dialog
        Navigator.of(context).pop();
        // Close Menu (optional, usually implied)

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('metadata_updated')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close Loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${LanguageService().getText('metadata_update_error')}: $e',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      print('Metadata update error: $e');
    }
  }
}

class CustomTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight!;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final activeTrackColor = sliderTheme.activeTrackColor!;
    final inactiveTrackColor = sliderTheme.inactiveTrackColor!;
    final activePaint = Paint()..color = activeTrackColor;
    final inactivePaint = Paint()..color = inactiveTrackColor;

    final double trackHeight = trackRect.height;
    final double trackRadius = trackHeight / 2;

    // Primero dibuja la barra completa inactiva (fondo)
    final RRect inactiveTrackRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRadius),
    );
    context.canvas.drawRRect(inactiveTrackRRect, inactivePaint);

    // Luego dibuja la parte activa encima (desde el inicio hasta el thumb)
    final Rect activeTrackRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbCenter.dx,
      trackRect.bottom,
    );

    final RRect activeTrackRRect = RRect.fromRectAndRadius(
      activeTrackRect,
      Radius.circular(trackRadius),
    );
    context.canvas.drawRRect(activeTrackRRect, activePaint);
  }
}

class TransparentThumbShape extends SliderComponentShape {
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(24, 24); // Large touch target
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    // Paint nothing
  }
}
