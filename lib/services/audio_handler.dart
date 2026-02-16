import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'audio_player_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart' as app_state;

import 'widget_service.dart';
import 'playlist_service.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayerService _player = AudioPlayerService();

  static final _shuffleControl = MediaControl(
    androidIcon: 'drawable/ic_shuffle',
    label: 'Shuffle',
    action: MediaAction.setShuffleMode,
  );

  static final _favoriteControl = MediaControl(
    androidIcon: 'drawable/ic_favorite',
    label: 'Favorite',
    action: MediaAction.custom,
    customAction: const CustomMediaAction(name: 'toggleFavorite'),
  );

  static final _unfavoriteControl = MediaControl(
    androidIcon: 'drawable/ic_favorite_border',
    label: 'Unfavorite',
    action: MediaAction.custom,
    customAction: const CustomMediaAction(name: 'toggleFavorite'),
  );

  MyAudioHandler() {
    print('[AudioHandler] Initializing...');

    // Sincronizar estado de reproducción (usando stream de eventos crudos para mayor precisión)
    _player.playbackRefreshStream.listen((_) {
      _broadcastState();
    });

    // Sincronizar cambios de estado explícitos (Play/Pause/Loading)
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
      if (current != null) {
        // Usar la duración del modelo si existe, sino la del player
        _updateMediaItem(current, current.duration ?? duration);
      }
    });

    // Escuchar cambios en favoritos para actualizar el widget y notificación
    PlaylistService().favoritesNotifier.addListener(() {
      _broadcastState(); // Para actualizar el icono de favoritos

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
    final playing = state == app_state.PlayerState.playing;
    final currentSong = _player.currentSong;
    final isLiked =
        currentSong != null && PlaylistService().isLiked(currentSong.id);

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          _shuffleControl,
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          isLiked ? _favoriteControl : _unfavoriteControl,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [
          1,
          2,
          3,
        ], // Previous, Play/Pause, Next
        playing: playing,
        processingState: _mapProcessingState(state),
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

  // Set shuffle mode
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    // Toggle shuffle regardless of argument because our internal logic is toggle-based
    // or we can check. For now, calling toggleShuffle matches existing logic.
    _player.toggleShuffle();
    _broadcastState();
  }

  Future<void> onCustomAction(String name, Map<String, dynamic>? extras) async {
    // Handle custom actions by name
    if (name == 'toggleShuffle') {
      _player.toggleShuffle();
      _broadcastState();
    } else if (name == 'toggleFavorite') {
      final song = _player.currentSong;
      if (song != null) {
        await PlaylistService().toggleLike(song);
        _broadcastState();
      }
    }
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    await onCustomAction(name, extras);
  }
}
