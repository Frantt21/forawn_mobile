import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'audio_player_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart' as app_state;

import 'widget_service.dart';
import 'playlist_service.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayerService _player = AudioPlayerService();

  MyAudioHandler() {
    print('[AudioHandler] Initializing...');

    // Sincronizar estado de reproducción (usando stream de eventos crudos para mayor precisión)
    _player.playbackRefreshStream.listen((_) {
      _broadcastState();
    });

    // Sincronizar cambios de estado explícitos (Play/Pause/Loading)
    // Esto es crucial porque playbackEventStream puede no emitir inmediatamente el cambio de booleano 'playing'
    _player.playerStateStream.listen((state) {
      _broadcastState();
      // Actualizar Widget
      final song = _player.currentSong;
      WidgetService.updateWidget(
        song: song,
        isPlaying: state == app_state.PlayerState.playing,
        isFavorite: song != null ? PlaylistService().isLiked(song.id) : false,
      );
    });

    // Sincronizar canción actual (MediaItem)
    _player.currentSongStream.listen((song) async {
      _updateMediaItem(song, null);
      // Actualizar Widget
      WidgetService.updateWidget(
        song: song,
        isPlaying: _player.playerState == app_state.PlayerState.playing,
        isFavorite: song != null ? PlaylistService().isLiked(song.id) : false,
      );
    });

    // Sincronizar duración real (Importante para que la barra de progreso tenga "fin")
    _player.durationStream.listen((duration) {
      final current = _player.currentSong;
      if (current != null && duration != null) {
        _updateMediaItem(current, duration);
      }
    });

    // Escuchar cambios en favoritos para actualizar el widget
    PlaylistService().favoritesNotifier.addListener(() {
      final song = _player.currentSong;
      if (song != null) {
        WidgetService.updateWidget(
          song: song,
          isPlaying: _player.playerState == app_state.PlayerState.playing,
          isFavorite: PlaylistService().isLiked(song.id),
        );
      }
    });
  }

  void _broadcastState() {
    final state = _player.playerState;
    // print('[AudioHandler] Broadcasting state: $state'); // Debug (opcional)

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
        // updatePosition must be fresh for the progress bar to sync correctly
        updatePosition: _player.currentPosition,
        bufferedPosition: _player.bufferedPosition,
        speed: 1.0,
        queueIndex: 0,
      ),
    );
  }

  void _updateMediaItem(Song? song, Duration? duration) {
    if (song == null) {
      mediaItem.add(null);
      return;
    }

    Uri? artUri;
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
        // Usar duración reportada por el player si existe, sino la del modelo
        duration: duration ?? song.duration,
        artUri: artUri,
      ),
    );
  }

  AudioProcessingState _mapProcessingState(app_state.PlayerState state) {
    switch (state) {
      case app_state.PlayerState.idle:
        // Evitar reportar idle si hay canción cargada para no "matar" el servicio de notificación
        // Esto previene flickering y potenciales crashes en release por reinicio del servicio
        return _player.currentSong != null
            ? AudioProcessingState.buffering
            : AudioProcessingState.idle;
      case app_state.PlayerState.loading:
        return AudioProcessingState.buffering;
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
    // await stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'toggleFavorite') {
      final song = _player.currentSong;
      if (song != null) {
        await PlaylistService().toggleLike(song.id);
        // La actualización del widget ocurrirá automáticamente gracias al listener de favoritesNotifier
      }
    }
  }
}
