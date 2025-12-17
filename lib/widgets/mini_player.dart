// lib/widgets/mini_player.dart
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
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
      builder: (context, snapshot) {
        final song = snapshot.data;
        if (song == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: () {
            // Abrir reproductor
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MusicPlayerScreen()),
            );
          },
          child: Container(
            height: 64,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  // Artwork
                  AspectRatio(
                    aspectRatio: 1,
                    child: song.artworkData != null
                        ? Image.memory(song.artworkData!, fit: BoxFit.cover)
                        : Container(
                            color: Colors.grey[850],
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white54,
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
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
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
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
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
              ),
            ),
          ),
        );
      },
    );
  }
}
