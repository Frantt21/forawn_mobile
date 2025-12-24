// lib/screens/music_player_screen.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
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
            IconButton(
              icon: Icon(
                _showLyrics ? Icons.music_note : Icons.lyrics,
                color: Colors.white,
              ),
              onPressed: () {
                setState(() => _showLyrics = !_showLyrics);
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
        ],
      ),
    );
  }
}
