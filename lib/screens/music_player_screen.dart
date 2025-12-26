// lib/screens/music_player_screen.dart
import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../services/playlist_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart';
import '../services/lyrics_service.dart';
import '../widgets/lyrics_view.dart';

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final AudioPlayerService _player = AudioPlayerService();
  bool _showLyrics = false;
  Lyrics? _currentLyrics;
  String? _lastSongId;

  @override
  void initState() {
    super.initState();
    // Cargar lyrics cuando cambia la canción
    _player.currentSongStream.listen((song) {
      if (song != null) {
        if (_lastSongId != song.id) {
          _lastSongId = song.id;
          _loadLyrics(song);
        }
      } else {
        if (mounted) setState(() => _currentLyrics = null);
      }
    });
  }

  Future<void> _loadLyrics(Song song) async {
    // Buscar en caché/API
    // Usamos el título y artista LIMPIOS de los metadatos si es posible
    final lyrics = await LyricsService().fetchLyrics(song.title, song.artist);
    if (mounted) {
      setState(() => _currentLyrics = lyrics);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Song?>(
        stream: _player.currentSongStream,
        builder: (context, snapshot) {
          final song = snapshot.data;

          if (song == null) {
            // Manejar caso null pero mostrando UI base o loader
            return Container(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            );
          }

          return Stack(
            children: [
              // Fondo con blur
              _buildBackground(song),

              // Contenido Principal
              SafeArea(
                child: Column(
                  children: [
                    // Header
                    _buildHeader(context),

                    // Contenido central (Artwork o Lyrics)
                    Expanded(
                      child: GestureDetector(
                        onHorizontalDragEnd: (details) {
                          if (details.primaryVelocity! < 0) {
                            _player.skipToNext();
                          } else if (details.primaryVelocity! > 0) {
                            _player.skipToPrevious();
                          }
                        },
                        onVerticalDragEnd: (details) {
                          // Detectar swipe hacia abajo (velocidad positiva) para cerrar
                          if (details.primaryVelocity! > 500) {
                            Navigator.of(context).pop();
                          }
                        },
                        child: _showLyrics
                            ? LyricsView(
                                lyrics: _currentLyrics,
                                progressStream: _player.progressStream,
                                onSeek: (pos) => _player.seek(pos),
                                key: ValueKey(
                                  song.id,
                                ), // Forzar rebuild al cambiar canción
                              )
                            : _buildArtwork(song),
                      ),
                    ),

                    // Info de canción y Controles
                    _buildControls(song),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBackground(Song song) {
    return Container(
      decoration: const BoxDecoration(color: Colors.black),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (song.artworkData != null)
            Image.memory(
              song.artworkData!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          else
            // Intentar usar un color derivado o fallback
            Container(color: Colors.grey[900]),

          // Blur y oscurecimiento
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              color: Colors.black.withOpacity(
                0.6,
              ), // Más oscuro para legibilidad
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! > 0) {
          Navigator.of(context).pop();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

            // Título dinámico
            Text(
              _showLyrics
                  ? LanguageService().getText('lyrics').toUpperCase()
                  : LanguageService().getText('now_playing').toUpperCase(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),

            // Menú de opciones
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: Colors.grey[900],
              onSelected: (value) async {
                final currentSong = await _player.currentSongStream.first;
                if (currentSong == null) return;

                switch (value) {
                  case 'like':
                    // Toggle favoritos usando el servicio
                    final isLiked = PlaylistService().isLiked(currentSong.id);
                    await PlaylistService().toggleLike(currentSong.id);

                    // if (mounted) {
                    //   ScaffoldMessenger.of(context).showSnackBar(
                    //     SnackBar(
                    //       content: Text(
                    //         isLiked
                    //             ? LanguageService().getText(
                    //                 'removed_from_favorites',
                    //               )
                    //             : LanguageService().getText(
                    //                 'added_to_favorites',
                    //               ),
                    //       ),
                    //       backgroundColor: isLiked
                    //           ? Colors.grey[700]
                    //           : Colors.purpleAccent,
                    //     ),
                    //   );
                    // }
                    break;
                  case 'add_to_playlist':
                    // Mostrar diálogo de agregar a playlist
                    if (mounted) {
                      _showAddToPlaylistDialog(context, currentSong);
                    }
                    break;
                }
              },
              itemBuilder: (context) {
                // Obtener canción actual para verificar estado
                final currentSong = _player.currentSong;
                final isLiked = currentSong != null
                    ? PlaylistService().isLiked(currentSong.id)
                    : false;

                return [
                  PopupMenuItem(
                    value: 'like',
                    child: Row(
                      children: [
                        Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                          color: isLiked ? Colors.purpleAccent : Colors.white,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isLiked
                              ? LanguageService().getText(
                                  'remove_from_favorites',
                                )
                              : LanguageService().getText('add_to_favorites'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'add_to_playlist',
                    child: Row(
                      children: [
                        const Icon(Icons.playlist_add, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          LanguageService().getText('add_to_playlist'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(Song song) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: song.artworkData != null
                ? Image.memory(song.artworkData!, fit: BoxFit.cover)
                : Container(
                    color: Colors.grey[800],
                    child: const Icon(
                      Icons.music_note,
                      size: 80,
                      color: Colors.white30,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Título y Artista
          Text(
            song.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26, // Más grande
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            song.artist,
            style: const TextStyle(color: Colors.white60, fontSize: 18),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 30),

          // Slider de Progreso
          StreamBuilder<PlaybackProgress>(
            stream: _player.progressStream,
            builder: (context, snapshot) {
              final progress = snapshot.data ?? PlaybackProgress.zero();

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withOpacity(0.2),
                    ),
                    child: Slider(
                      value: progress.position.inMilliseconds.toDouble().clamp(
                        0.0,
                        progress.duration.inMilliseconds.toDouble(),
                      ),
                      min: 0.0,
                      max: progress.duration.inMilliseconds.toDouble() > 0
                          ? progress.duration.inMilliseconds.toDouble()
                          : 1.0,
                      onChanged: (value) {
                        _player.seek(Duration(milliseconds: value.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
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
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Shuffle Toggle
              StreamBuilder<bool>(
                stream: _player.shuffleModeStream,
                builder: (context, snapshot) {
                  final isShuffle = snapshot.data ?? false;
                  return IconButton(
                    icon: Icon(
                      Icons.shuffle,
                      color: isShuffle ? Colors.purpleAccent : Colors.white,
                    ),
                    onPressed: _player.toggleShuffle,
                  );
                },
              ),

              // Previous
              IconButton(
                icon: const Icon(
                  Icons.skip_previous_rounded,
                  color: Colors.white,
                  size: 42,
                ),
                onPressed: _player.skipToPrevious,
              ),

              // Play/Pause
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final state = snapshot.data ?? PlayerState.idle;
                  final isPlaying = state == PlayerState.playing;
                  final isBuffering =
                      state == PlayerState.buffering ||
                      state == PlayerState.loading;

                  return Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: IconButton(
                      icon: isBuffering
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                              color: Colors.black,
                            ),
                      onPressed: isPlaying ? _player.pause : _player.play,
                    ),
                  );
                },
              ),

              // Next
              IconButton(
                icon: const Icon(
                  Icons.skip_next_rounded,
                  color: Colors.white,
                  size: 42,
                ),
                onPressed: _player.skipToNext,
              ),

              // Repeat Mode
              StreamBuilder<RepeatMode>(
                stream: _player.repeatModeStream,
                builder: (context, snapshot) {
                  final mode = snapshot.data ?? RepeatMode.off;
                  IconData icon;
                  Color color;

                  switch (mode) {
                    case RepeatMode.one:
                      icon = Icons.repeat_one_rounded;
                      color = Colors.purpleAccent;
                      break;
                    case RepeatMode.all:
                      icon = Icons.repeat_rounded;
                      color = Colors.purpleAccent;
                      break;
                    case RepeatMode.off:
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

          const SizedBox(height: 24),

          // Botón de Lyrics translúcido
          GestureDetector(
            onTap: () {
              setState(() => _showLyrics = !_showLyrics);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showLyrics ? Icons.music_note : Icons.lyrics,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _showLyrics
                            ? LanguageService().getText('hide_lyrics')
                            : LanguageService().getText('show_lyrics'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Mostrar diálogo para agregar a playlist
  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                          color: Colors.purpleAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.purpleAccent.withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.purpleAccent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.add_circle_outline,
                                color: Colors.purpleAccent,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              LanguageService().getText('new_playlist'),
                              style: const TextStyle(
                                color: Colors.purpleAccent,
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
                                                Colors.purpleAccent,
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
                                                        File(
                                                          playlist.imagePath!,
                                                        ),
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
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
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
                                              LanguageService().getText(
                                                'added',
                                              ),
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
              ),
            ),
          ),
        );
      },
    );
  }
}
