import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'audio_player_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart' as app_state;

import 'widget_service.dart';
import 'playlist_service.dart';

/// Puente hacia la sesión de medios del OS vía audio_service.
///
/// Sigue el patrón probado de Scrup (scrup_audio_handler.dart):
///  - El MediaItem se publica INMEDIATAMENTE al cambiar de canción (sin
///    debounce): la notificación necesita el metadata de la sesión para
///    pintar título/artista/artwork; con debounce llegaba vacío o tarde.
///  - El estado se publica con eco inmediato en play/pause/seek/next/prev.
///  - La posición se publica con throttle de ~1Hz para no saturar la
///    sesión ni la notificación.
///  - La duración real se re-emite con copyWith: sin ella la barra de
///    progreso queda sin "fin" y SystemUI no pinta timestamps.
///  - No se publica estado sin canción: el overlay del OS se activa con
///    la primera pista.
class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayerService _player = AudioPlayerService();

  // Acciones custom de la notificación (van a la media session; el sistema
  // las muestra en el reproductor expandido en Android 13+).
  static const _shuffleAction = 'forawn.action.TOGGLE_SHUFFLE';
  static const _favoriteAction = 'forawn.action.TOGGLE_FAVORITE';

  bool _hasTrack = false;
  bool _playing = false;
  bool _buffering = false;
  bool _shuffle = false;
  Duration _lastPosition = Duration.zero;
  Song? _currentSong;

  // Throttle de posición a ~1Hz para no saturar el overlay del OS.
  int _lastPublishedSec = -1;

  MyAudioHandler() {
    print('[AudioHandler] Initializing...');

    // Canción actual → MediaItem inmediato (SIN debounce: la notificación
    // necesita el metadata apenas cambia la pista).
    _player.currentSongStream.listen((song) {
      _currentSong = song;
      _hasTrack = song != null;
      if (song == null) {
        mediaItem.add(null);
      } else {
        mediaItem.add(_mediaItemFor(song));
      }
      _lastPublishedSec = -1; // fuerza republicación con la nueva pista
      _publishPlaybackState();
      _updateWidget();
    });

    // Estado de reproducción (play/pausa/carga) → eco inmediato al OS.
    _player.playerStateStream.listen((state) {
      final wasBuffering = _buffering;
      _playing = state == app_state.PlayerState.playing;
      _buffering = state == app_state.PlayerState.loading ||
          state == app_state.PlayerState.buffering ||
          (state == app_state.PlayerState.idle && _hasTrack);
      // Solo publicar si cambió algo visible (evita spam del stream).
      if (_playing ||
          wasBuffering != _buffering ||
          playbackState.value.playing != _playing) {
        _publishPlaybackState();
      }
      _updateWidget();
    });

    // Cualquier evento crudo del player (seek, buffer, cambio de pista
    // cruzada) → actualiza la posición publicada con throttle 1Hz.
    _player.playbackRefreshStream.listen((_) {
      _lastPosition = _player.currentPosition;
      final sec = _lastPosition.inMilliseconds ~/ 1000;
      if (sec == _lastPublishedSec) return;
      _lastPublishedSec = sec;
      _publishPlaybackState();
    });

    // Duración real: llega DESPUÉS de publicar la pista. Se re-emite el
    // MediaItem con copyWith para que la notificación pinta el timestamp
    // total y la barra de progreso con "fin".
    _player.durationStream.listen((duration) {
      final item = mediaItem.value;
      if (item == null || duration == null) return;
      if (item.duration == duration) return;
      mediaItem.add(item.copyWith(duration: duration));
    });

    // Shuffle: intercambiar el icono de la acción custom.
    _player.shuffleModeStream.listen((enabled) {
      if (enabled == _shuffle) return;
      _shuffle = enabled;
      _publishPlaybackState();
    });

    // Favoritos: actualizar el icono (y el widget).
    PlaylistService().favoritesNotifier.addListener(() {
      _publishPlaybackState();
      _updateWidget();
    });
  }

  void _updateWidget() {
    final song = _player.currentSong;
    WidgetService.updateWidget(
      song: song,
      isPlaying: _player.playerState == app_state.PlayerState.playing,
      isFavorite: song != null ? PlaylistService().isLiked(song.id) : false,
    );
  }

  MediaItem _mediaItemFor(Song song) {
    Uri? artUri;
    if (song.artworkPath != null) {
      artUri = Uri.file(song.artworkPath!);
    } else if (song.artworkUri != null) {
      artUri = Uri.tryParse(song.artworkUri!);
    }
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album ?? '',
      duration: song.duration,
      artUri: artUri,
    );
  }

  void _publishPlaybackState() {
    // Sin pista no se publica nada: el overlay del OS se activa con la
    // primera pista (igual que Scrup). Publicar idle desde el arranque
    // deja la sesión en STATE_NONE y SystemUI no pinta nada.
    if (!_hasTrack) return;

    final song = _currentSong;
    final isLiked = song != null && PlaylistService().isLiked(song.id);

    // Orden fijo: [shuffle, prev, play/pausa, next, favorito]. Las acciones
    // custom viajan en la media session; las ESTÁNDAR (prev/play/next) son
    // las que pinta la notificación compacta. nativeActions resultantes =
    // [prev(0), play(1), next(2)] → compactas [0, 1, 2].
    final controls = [
      MediaControl.custom(
        androidIcon:
            _shuffle ? 'drawable/ic_shuffle' : 'drawable/ic_shuffle_off',
        label: _shuffle ? 'Shuffle on' : 'Shuffle off',
        name: _shuffleAction,
      ),
      MediaControl.skipToPrevious,
      _playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.custom(
        androidIcon:
            isLiked ? 'drawable/ic_favorite' : 'drawable/ic_favorite_border',
        label: isLiked ? 'Unfavorite' : 'Favorite',
        name: _favoriteAction,
      ),
    ];

    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.setShuffleMode,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: _playing,
        updatePosition: _lastPosition,
        bufferedPosition: _player.bufferedPosition,
        speed: 1.0,
      ),
    );
  }

  // ------------------------------------------------------ comandos del OS

  @override
  Future<void> play() async {
    if (!_hasTrack) return;
    // Eco inmediato: SystemUI reacciona al toque sin esperar al engine.
    _playing = true;
    _publishPlaybackState();
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (!_hasTrack) return;
    _playing = false;
    _publishPlaybackState();
    await _player.pause();
  }

  @override
  Future<void> skipToNext() async {
    _lastPublishedSec = -1;
    await _player.skipToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    _lastPublishedSec = -1;
    await _player.skipToPrevious();
  }

  @override
  Future<void> seek(Duration position) async {
    _lastPosition = position;
    // Forzar el siguiente evento de posición más allá del throttle.
    _lastPublishedSec = -1;
    _publishPlaybackState();
    await _player.seek(position);
  }

  // Reconciliar el modo shuffle del sistema con el de la app sin
  // togglear dos veces el mismo estado.
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    if (enabled != _shuffle) {
      _player.toggleShuffle();
    }
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {
      case _shuffleAction:
        // El stream de shuffle actualiza el icono y republica.
        _player.toggleShuffle();
        _shuffle = _player.isShuffle;
        _publishPlaybackState();
        return Future.value();
      case _favoriteAction:
        final song = _currentSong;
        if (song != null) {
          await PlaylistService().toggleLike(song);
        }
        _publishPlaybackState();
        return Future.value();
      default:
        return super.customAction(name, extras);
    }
  }

  @override
  Future<void> stop() async {
    // Publicar pausa antes de limpiar la pista (el guard usa _hasTrack).
    _playing = false;
    _publishPlaybackState();
    _hasTrack = false;
    _currentSong = null;
    mediaItem.add(null);
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
    // Mantener la reproducción al quitar la app de recientes (igual que antes).
  }
}
