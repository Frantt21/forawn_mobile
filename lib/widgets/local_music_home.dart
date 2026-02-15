import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist_model.dart';
import '../services/music_history_service.dart';
import '../services/playlist_service.dart';
import '../services/language_service.dart';
import '../services/audio_player_service.dart';

import 'dart:io';

import '../widgets/artwork_widget.dart';
import 'animated_playing_indicator.dart';

class LocalMusicHome extends StatelessWidget {
  final Function(Song) onSongTap;
  final VoidCallback onCreatePlaylist;
  final Function(Playlist) onPlaylistTap;
  final List<Song> favoriteSongs;
  final int currentTabIndex;

  const LocalMusicHome({
    super.key,
    required this.onSongTap,
    required this.onCreatePlaylist,
    required this.onPlaylistTap,
    required this.favoriteSongs,
    this.currentTabIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Escuchar cambios en historial y playlists
    return StreamBuilder<Song?>(
      stream: AudioPlayerService().currentSongStream,
      builder: (context, songSnapshot) {
        final currentSong = songSnapshot.data;

        return ListenableBuilder(
          listenable: Listenable.merge([
            MusicHistoryService(),
            PlaylistService(),
            LanguageService(),
          ]),
          builder: (context, _) {
            final history = MusicHistoryService().history.take(10).toList();
            // Sort playlists by sorting logic in service (pinned, lastOpened, createdAt)
            // The service already handles sorting, so we just take the list.
            final playlists = PlaylistService().playlists;
            // Filter empty if needed, or just take top.
            // User asked for "last opened or played". Service now handles this sort.
            final recentPlaylists = playlists.take(6).toList();

            final bool isEmpty =
                history.isEmpty && playlists.isEmpty && favoriteSongs.isEmpty;

            if (isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.library_music_outlined,
                      size: 80,
                      color: Colors.white.withOpacity(0.2),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      LanguageService().getText('no_recent_activity'),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: onCreatePlaylist,
                      icon: const Icon(Icons.add),
                      label: Text(LanguageService().getText('create_playlist')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purpleAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Historial Reciente
                  if (history.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                        LanguageService().getText('recently_played'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: GridView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 1.0, // 1:1 Aspect Ratio
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: history.length > 6 ? 6 : history.length,
                        itemBuilder: (context, index) {
                          final song = history[index];
                          final isCurrentSong = currentSong?.id == song.id;
                          Color dominantColor = song.dominantColor != null
                              ? Color(song.dominantColor!)
                              : Colors.purpleAccent;

                          if (isCurrentSong) {
                            dominantColor =
                                HSLColor.fromColor(dominantColor).lightness <
                                    0.3
                                ? HSLColor.fromColor(
                                    dominantColor,
                                  ).withLightness(0.6).toColor()
                                : dominantColor;
                          }

                          return GestureDetector(
                            onTap: () => onSongTap(song),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                                border: isCurrentSong
                                    ? Border.all(color: dominantColor, width: 3)
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  isCurrentSong ? 9 : 12,
                                ), // Adjust for border
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        return ArtworkWidget(
                                          artworkPath: song.artworkPath,
                                          artworkUri: song.artworkUri,
                                          width: constraints.maxWidth,
                                          height: constraints.maxHeight,
                                          fit: BoxFit.cover,
                                          dominantColor: song.dominantColor,
                                        );
                                      },
                                    ),
                                    // Gradient Overlay
                                    Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black.withOpacity(0.8),
                                          ],
                                          stops: const [0.6, 1.0],
                                        ),
                                      ),
                                    ),
                                    // Text Content
                                    Positioned(
                                      left: 8,
                                      right: 8,
                                      bottom: 8,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            song.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            song.artist,
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.8,
                                              ),
                                              fontSize: 10,
                                              shadows: const [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Active Indicator
                                    if (isCurrentSong)
                                      Positioned(
                                        right: 8,
                                        top: 8,
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: AnimatedPlayingIndicator(
                                            color: dominantColor,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // Playlists Recientes
                  if (recentPlaylists.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            LanguageService().getText('recent_playlists'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: onCreatePlaylist,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                LanguageService().getText('new'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 180, // Ajustado para formato cuadrado
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: recentPlaylists.length,
                        itemBuilder: (context, index) {
                          final playlist = recentPlaylists[index];
                          return Container(
                            width: 160, // Más cuadrado
                            margin: const EdgeInsets.only(right: 12),
                            child: GestureDetector(
                              onTap: () => onPlaylistTap(playlist),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.grey[900],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      // Background image logic with fallback
                                      Builder(
                                        builder: (context) {
                                          // 1. Imagen Personalizada
                                          if (playlist.imagePath != null &&
                                              File(
                                                playlist.imagePath!,
                                              ).existsSync()) {
                                            return Image.file(
                                              File(playlist.imagePath!),
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Container(
                                                    color: Colors.grey[850],
                                                    child: const Icon(
                                                      Icons.music_note,
                                                      color: Colors.white24,
                                                    ),
                                                  ),
                                            );
                                          }

                                          // 2. Collage de 4 imágenes
                                          // Recolectar hasta 4 artworks únicos
                                          final artworks = <String>[];
                                          for (var song in playlist.songs) {
                                            if (song.artworkPath != null &&
                                                File(
                                                  song.artworkPath!,
                                                ).existsSync() &&
                                                !artworks.contains(
                                                  song.artworkPath,
                                                )) {
                                              artworks.add(song.artworkPath!);
                                              if (artworks.length >= 4) break;
                                            }
                                          }

                                          if (artworks.length >= 4) {
                                            return Column(
                                              children: [
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: Image.file(
                                                          File(artworks[0]),
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child: Image.file(
                                                          File(artworks[1]),
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: Image.file(
                                                          File(artworks[2]),
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child: Image.file(
                                                          File(artworks[3]),
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            );
                                          }

                                          // 3. Fallback: Primera canción o Icono
                                          if (artworks.isNotEmpty) {
                                            return Image.file(
                                              File(artworks.first),
                                              fit: BoxFit.cover,
                                            );
                                          }

                                          return const Center(
                                            child: Icon(
                                              Icons.music_note,
                                              color: Colors.white24,
                                              size: 40,
                                            ),
                                          );
                                        },
                                      ),
                                      // Gradient overlay
                                      Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.transparent,
                                              Colors.black.withOpacity(0.8),
                                            ],
                                            stops: const [0.5, 1.0],
                                          ),
                                        ),
                                      ),
                                      // Text overlay
                                      Positioned(
                                        bottom: 8,
                                        left: 8,
                                        right: 8,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _AutoScrollText(
                                              text: playlist.name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14, // Slightly bigger
                                                shadows: [
                                                  Shadow(
                                                    color: Colors.black,
                                                    blurRadius: 4,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${playlist.songs.length} ${LanguageService().getText('songs')}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.8,
                                                ),
                                                fontSize: 12,
                                                shadows: const [
                                                  Shadow(
                                                    color: Colors.black,
                                                    blurRadius: 4,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // Ultimas Favoritas
                  if (favoriteSongs.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            LanguageService().getText('favorite_songs'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              final favPlaylist = Playlist(
                                id: 'favorites_virtual',
                                name: LanguageService().getText('my_favorites'),
                                description: LanguageService().getText(
                                  'favorite_songs_desc',
                                ),
                                createdAt: DateTime.now(),
                                isPinned: true,
                                songs: favoriteSongs,
                              );
                              onPlaylistTap(favPlaylist);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                LanguageService().getText('view_all'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: GridView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 1.0,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: favoriteSongs.length > 6
                            ? 6
                            : favoriteSongs.length,
                        itemBuilder: (context, index) {
                          // Show in reverse order (LIFO)
                          final reversedIndex =
                              favoriteSongs.length - 1 - index;
                          final song = favoriteSongs[reversedIndex];
                          final isCurrentSong = currentSong?.id == song.id;
                          Color dominantColor = song.dominantColor != null
                              ? Color(song.dominantColor!)
                              : Colors.purpleAccent;

                          if (isCurrentSong) {
                            dominantColor =
                                HSLColor.fromColor(dominantColor).lightness <
                                    0.3
                                ? HSLColor.fromColor(
                                    dominantColor,
                                  ).withLightness(0.6).toColor()
                                : dominantColor;
                          }

                          return GestureDetector(
                            onTap: () => onSongTap(song),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                                border: isCurrentSong
                                    ? Border.all(color: dominantColor, width: 3)
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  isCurrentSong ? 9 : 12,
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        return ArtworkWidget(
                                          artworkPath: song.artworkPath,
                                          artworkUri: song.artworkUri,
                                          width: constraints.maxWidth,
                                          height: constraints.maxHeight,
                                          fit: BoxFit.cover,
                                          dominantColor: song.dominantColor,
                                        );
                                      },
                                    ),
                                    // Gradient Overlay
                                    Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black.withOpacity(0.8),
                                          ],
                                          stops: const [0.6, 1.0],
                                        ),
                                      ),
                                    ),
                                    // Text Content
                                    Positioned(
                                      left: 8,
                                      right: 8,
                                      bottom: 8,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            song.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            song.artist,
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.8,
                                              ),
                                              fontSize: 10,
                                              shadows: const [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Active Indicator
                                    if (isCurrentSong)
                                      Positioned(
                                        right: 8,
                                        top: 8,
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: AnimatedPlayingIndicator(
                                            color: dominantColor,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // Si hay historial pero no playlists, mostrar botón crear playlist abajo
                  if (recentPlaylists.isEmpty && history.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: TextButton.icon(
                          onPressed: onCreatePlaylist,
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: Colors.purpleAccent,
                          ),
                          label: Text(
                            LanguageService().getText('create_first_playlist'),
                            style: const TextStyle(color: Colors.purpleAccent),
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
}

// Widget para texto con scroll automático
class _AutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _AutoScrollText({required this.text, required this.style});

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText>
    with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animationController;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkIfNeedsScroll();
    });
  }

  void _checkIfNeedsScroll() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        setState(() => _needsScroll = true);
        _startScrolling();
      }
    }
  }

  void _startScrolling() async {
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted || !_needsScroll) return;

    while (mounted && _needsScroll) {
      // Scroll to end
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(seconds: 2),
        curve: Curves.easeInOut,
      );
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      // Scroll back to start
      await _scrollController.animateTo(
        0,
        duration: const Duration(seconds: 2),
        curve: Curves.easeInOut,
      );
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.style.fontSize! * 1.5,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Text(widget.text, style: widget.style, maxLines: 1),
      ),
    );
  }
}
