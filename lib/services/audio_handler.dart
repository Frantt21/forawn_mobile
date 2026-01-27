import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'audio_player_service.dart';
import '../models/playback_state.dart' as app_state;

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayerService _player = AudioPlayerService();

  MyAudioHandler() {
    print('[AudioHandler] Initializing...');

    // Sincronizar estado de reproducción
    _player.playerStateStream.listen((state) {
      print('[AudioHandler] Player state changed: $state');
      final playing = state == app_state.PlayerState.playing;
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          playing: playing,
          processingState: _mapProcessingState(state),
          updatePosition: _player.currentPosition, // Necesitaría exponer esto
          bufferedPosition: _player.bufferedPosition,
          speed: 1.0,
          queueIndex:
              0, // No gestionamos queue completa en notification por ahora
        ),
      );
      print('[AudioHandler] Playback state updated: playing=$playing');
    });

    // Sincronizar canción actual (MediaItem)
    _player.currentSongStream.listen((song) async {
      if (song == null) {
        mediaItem.add(null);
        return;
      }

      Uri? artUri;
      // Usar artworkPath ya cacheado si existe
      if (song.artworkPath != null) {
        artUri = Uri.file(song.artworkPath!);
      } else if (song.artworkUri != null) {
        artUri = Uri.parse(song.artworkUri!);
      }

      mediaItem.add(
        MediaItem(
          id: song.id,
          title: song.title,
          artist: song.artist,
          album: song.album ?? '',
          duration: song.duration,
          artUri: artUri,
        ),
      );
    });
  }

  AudioProcessingState _mapProcessingState(app_state.PlayerState state) {
    switch (state) {
      case app_state.PlayerState.idle:
        return AudioProcessingState.idle;
      case app_state.PlayerState.loading:
        return AudioProcessingState.loading;
      case app_state.PlayerState.buffering:
        return AudioProcessingState.buffering;
      case app_state.PlayerState.playing:
        return AudioProcessingState.ready;
      case app_state.PlayerState.paused:
        return AudioProcessingState.ready;
      case app_state.PlayerState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> skipToNext() => _player.skipToNext();
  @override
  Future<void> skipToPrevious() => _player.skipToPrevious();
  @override
  Future<void> stop() async {
    await _player.stop();
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);
}
