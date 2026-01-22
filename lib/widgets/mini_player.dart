// lib/widgets/mini_player.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart';
import '../screens/music_player_screen.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();

    return StreamBuilder<Song?>(
      stream: player.currentSongStream,
      initialData: player
          .currentSong, // Use current song as initial data to prevent flash
      builder: (context, snapshot) {
        final song = snapshot.data;

        // Siempre mostrar el contenedor con estilo del Nav
        return GestureDetector(
          // Detectar arrastre vertical
          onVerticalDragUpdate: song != null
              ? (details) {
                  // Si arrastra hacia arriba (delta negativo), abrir reproductor
                  if (details.primaryDelta! < -5) {
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            const MusicPlayerScreen(),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              const begin = Offset(0.0, 1.0);
                              const end = Offset.zero;
                              const curve = Curves.easeOutCubic;

                              var tween = Tween(
                                begin: begin,
                                end: end,
                              ).chain(CurveTween(curve: curve));

                              return SlideTransition(
                                position: animation.drive(tween),
                                child: child,
                              );
                            },
                      ),
                    );
                  }
                }
              : null,
          onTap: song != null
              ? () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          const MusicPlayerScreen(),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                            const begin = Offset(0.0, 1.0);
                            const end = Offset.zero;
                            const curve = Curves.easeInOut;

                            var tween = Tween(
                              begin: begin,
                              end: end,
                            ).chain(CurveTween(curve: curve));

                            return SlideTransition(
                              position: animation.drive(tween),
                              child: child,
                            );
                          },
                    ),
                  );
                }
              : null,
          child: Container(
            height: 70,
            margin: const EdgeInsets.symmetric(
              vertical: 0,
            ), // Sin margin horizontal ni vertical
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    color:
                        (song?.dominantColor != null
                                ? Color(song!.dominantColor!)
                                : const Color.fromARGB(255, 45, 45, 45))
                            .withOpacity(0.7),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: song != null
                      ? _buildPlayerContent(song, player)
                      : _buildPlaceholder(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Contenido cuando hay música
  Widget _buildPlayerContent(Song song, AudioPlayerService player) {
    return Row(
      children: [
        // Artwork
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Hero(
            tag: 'artwork_${song.id}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 1,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: animation,
                            child: child,
                          ),
                        );
                      },
                  child: song.artworkData != null
                      ? Image.memory(
                          song.artworkData!,
                          key: ValueKey(song.id),
                          fit: BoxFit.cover,
                        )
                      : Container(
                          key: const ValueKey('placeholder'),
                          color: Colors.grey[850],
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white54,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),

        // Texto
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),

        // Controles
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snapshot) {
            final state = snapshot.data ?? PlayerState.idle;
            final isPlaying = state == PlayerState.playing;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                  color: Colors.white,
                  onPressed: () {
                    if (isPlaying) {
                      player.pause();
                    } else {
                      player.play();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  color: Colors.white,
                  onPressed: player.skipToNext,
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // Placeholder cuando no hay música (estilo Nav)
  Widget _buildPlaceholder() {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_note_outlined,
            color: Colors.white.withOpacity(0.3),
            size: 24,
          ),
          const SizedBox(width: 12),
          Text(
            LanguageService().getText('no_music'),
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
