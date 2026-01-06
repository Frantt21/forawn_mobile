// lib/services/audio_player_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/playback_state.dart'
    as app_state; // Alias para evitar conflicto con just_audio
import 'music_history_service.dart';
import 'music_metadata_cache.dart';
import 'saf_helper.dart';
import 'lyrics_service.dart';

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  final AudioPlayer _audioPlayer = AudioPlayer();

  AudioPlayerService._internal() {
    _init();
  }

  // Estado actual
  late final app_state.PlaybackHistory _history = app_state.PlaybackHistory();
  final Playlist _playlist = Playlist(name: 'Main Queue');

  // Flag para prevenir skips concurrentes
  bool _isSkipping = false;

  // Streams
  final _playlistSubject = BehaviorSubject<Playlist>();
  Stream<Playlist> get playlistStream => _playlistSubject.stream;

  final _currentSongSubject = BehaviorSubject<Song?>();
  Stream<Song?> get currentSongStream => _currentSongSubject.stream;
  Song? get currentSong => _playlist.currentSong;

  // Combinar posición y duración para progreso
  Stream<app_state.PlaybackProgress> get progressStream =>
      Rx.combineLatest3<
        Duration,
        Duration,
        Duration,
        app_state.PlaybackProgress
      >(
        _audioPlayer.positionStream,
        _audioPlayer.bufferedPositionStream,
        _audioPlayer.durationStream.map((d) => d ?? Duration.zero),
        (position, buffered, duration) => app_state.PlaybackProgress(
          position: position,
          bufferedPosition: buffered,
          duration: duration,
        ),
      );

  // Estado del reproductor mapeado al nuestro
  Stream<app_state.PlayerState> get playerStateStream => _audioPlayer
      .playerStateStream
      .map(_mapToAppPlayerState)
      .doOnData((state) {
        print('[AudioPlayerService] State changed: $state');
      });

  Stream<bool> get shuffleModeStream =>
      _playlistSubject.map((p) => p.isShuffle).distinct();

  Stream<app_state.RepeatMode> get repeatModeStream =>
      _playlistSubject.map((p) => p.repeatMode).distinct();

  // Initialization
  Future<void> _init() async {
    // Cargar preferencias guardadas
    await _loadPlaybackPreferences();

    // Configurar sesión de audio
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Escuchar errores
    _audioPlayer.playbackEventStream.listen(
      (event) {},
      onError: (Object e, StackTrace stackTrace) {
        print('[AudioPlayer] Error: $e');
      },
    );

    // Escuchar completado para auto-avance
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _onSongCompleted();
      }
    });

    // Guardar estado periódicamente
    _audioPlayer.positionStream.listen((position) {
      _savePlaybackPreferences(); // Guardar posición cada vez que cambia
    });

    // Inicializar streams subjects
    if (!_playlistSubject.hasValue) _playlistSubject.add(_playlist);
    if (!_currentSongSubject.hasValue) _currentSongSubject.add(null);
  }

  Future<void> _loadPlaybackPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cargar shuffle y repeat
      final shuffle = prefs.getBool('playback_shuffle') ?? false;
      final repeatIndex =
          prefs.getInt('playback_repeat') ??
          1; // 1 = RepeatMode.all por defecto

      _playlist.setShuffle(shuffle);
      _playlist.setRepeatMode(app_state.RepeatMode.values[repeatIndex]);

      // Cargar playlist guardada
      final playlistJson = prefs.getString('playback_playlist');
      final currentIndex = prefs.getInt('playback_current_index') ?? -1;
      final savedPosition = prefs.getInt('playback_position') ?? 0;

      if (playlistJson != null && playlistJson.isNotEmpty) {
        try {
          final List<dynamic> songsJson = json.decode(playlistJson);
          final songs = songsJson.map((s) => Song.fromJson(s)).toList();

          if (songs.isNotEmpty &&
              currentIndex >= 0 &&
              currentIndex < songs.length) {
            // Restaurar playlist sin auto-play
            await loadPlaylist(
              songs,
              initialIndex: currentIndex,
              autoPlay: false,
              addToHistory: false,
            );

            // Restaurar posición
            if (savedPosition > 0) {
              await seek(Duration(milliseconds: savedPosition));
            }

            print(
              '[AudioPlayer] Restored: ${songs.length} songs, index=$currentIndex, position=${Duration(milliseconds: savedPosition)}',
            );
          }
        } catch (e) {
          print('[AudioPlayer] Error parsing saved playlist: $e');
        }
      }

      print(
        '[AudioPlayer] Loaded preferences: shuffle=$shuffle, repeat=${app_state.RepeatMode.values[repeatIndex]}',
      );
    } catch (e) {
      print('[AudioPlayer] Error loading preferences: $e');
      // Si hay error, usar valores por defecto
      _playlist.setRepeatMode(app_state.RepeatMode.all);
    }
  }

  Future<void> _savePlaybackPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Guardar shuffle y repeat
      await prefs.setBool('playback_shuffle', _playlist.isShuffle);
      await prefs.setInt('playback_repeat', _playlist.repeatMode.index);

      // Guardar playlist actual
      if (_playlist.songs.isNotEmpty) {
        final playlistJson = json.encode(
          _playlist.songs.map((s) => s.toJson()).toList(),
        );
        await prefs.setString('playback_playlist', playlistJson);
        await prefs.setInt('playback_current_index', _playlist.currentIndex);

        // Guardar posición actual
        final position = _audioPlayer.position.inMilliseconds;
        await prefs.setInt('playback_position', position);
      }
    } catch (e) {
      print('[AudioPlayer] Error saving preferences: $e');
    }
  }

  // --- Controles Básicos ---

  Future<void> play() async {
    if (_playlist.currentSong == null && _playlist.isNotEmpty) {
      // Si no hay canción actual pero hay playlist, reproducir la primera o la última guardada
      await skipToNext();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> pause() async => await _audioPlayer.pause();

  Future<void> stop() async {
    await _audioPlayer.stop();
    await _audioPlayer.seek(Duration.zero);
  }

  Future<void> seek(Duration position) async =>
      await _audioPlayer.seek(position);

  Duration get currentPosition => _audioPlayer.position;
  Duration get bufferedPosition => _audioPlayer.bufferedPosition;

  // --- Gestión de Playlist ---

  /// Cargar una lista de canciones y empezar a reproducir
  /// Cargar una lista de canciones y empezar a reproducir
  Future<void> loadPlaylist(
    List<Song> songs, {
    int initialIndex = 0,
    bool autoPlay = true,
    bool addToHistory = true,
  }) async {
    // Verificar si la playlist es la misma para no reiniciar estado
    final currentSongs = _playlist.songs;
    bool isSame = false;
    if (currentSongs.length == songs.length) {
      isSame = true;
      for (int i = 0; i < songs.length; i++) {
        if (currentSongs[i].id != songs[i].id) {
          isSame = false;
          break;
        }
      }
    }

    if (isSame) {
      // Si es la misma playlist, solo cambiar canción si se solicita explícitamente
      if (initialIndex >= 0 && initialIndex < songs.length) {
        // Solo reproducir si es diferente a la actual o si no está reproduciendo
        if (_playlist.currentIndex != initialIndex) {
          _playlist.setCurrentIndex(initialIndex);
          await _playCurrentSong(playNow: autoPlay, addToHistory: addToHistory);
        } else if (autoPlay && !_audioPlayer.playing) {
          await play();
        }
      }
      // No hacer nada más si ya está cargada
      return;
    }

    _playlist.clear();
    _playlist.addAll(songs);

    if (initialIndex >= 0 && initialIndex < songs.length) {
      _playlist.setCurrentIndex(initialIndex);
      // Siempre cargar la canción actual, pero reproducir solo si autoPlay es true
      await _playCurrentSong(playNow: autoPlay, addToHistory: addToHistory);
    }

    _playlistSubject.add(_playlist);
  }

  /// Agregar canción al final
  void addToQueue(Song song) {
    _playlist.add(song);
    _playlistSubject.add(_playlist);
  }

  /// Cambiar modo de reproducción
  void toggleShuffle() {
    _playlist.setShuffle(!_playlist.isShuffle);
    _playlistSubject.add(_playlist);
    _savePlaybackPreferences();
  }

  void toggleRepeat() {
    final current = _playlist.repeatMode;
    var next = app_state.RepeatMode.off;

    if (current == app_state.RepeatMode.off) {
      next = app_state.RepeatMode.all;
    } else if (current == app_state.RepeatMode.all) {
      next = app_state.RepeatMode.one;
    } else {
      next = app_state.RepeatMode.off;
    }

    _playlist.setRepeatMode(next);
    _playlistSubject.add(_playlist);
    _savePlaybackPreferences();
  }

  // --- Navegación ---

  Future<void> skipToNext() async {
    // Prevenir skips concurrentes
    if (_isSkipping) {
      print('[AudioPlayer] Skip already in progress, ignoring');
      return;
    }

    _isSkipping = true;
    try {
      final nextIndex = _playlist.nextIndex;
      if (nextIndex != null) {
        _playlist.setCurrentIndex(nextIndex);
        await _playCurrentSong().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('[AudioPlayer] Playback timeout in skipToNext');
            return false;
          },
        );
      } else {
        // Fin de playlist
        await stop();
      }

      // Pequeño delay para evitar skips muy rápidos
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      print('[AudioPlayer] Error in skipToNext: $e');
    } finally {
      _isSkipping = false;
    }
  }

  Future<void> skipToPrevious() async {
    // Prevenir skips concurrentes
    if (_isSkipping) {
      print('[AudioPlayer] Skip already in progress, ignoring');
      return;
    }

    _isSkipping = true;
    try {
      // Si la canción lleva más de 3 segundos, reiniciar
      if (_audioPlayer.position.inSeconds > 3) {
        await seek(Duration.zero);
        return;
      }

      final prevIndex = _playlist.previousIndex;
      if (prevIndex != null) {
        _playlist.setCurrentIndex(prevIndex);
        await _playCurrentSong().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('[AudioPlayer] Playback timeout in skipToPrevious');
            return false;
          },
        );
      } else {
        // Al principio de playlist, parar o reiniciar
        await seek(Duration.zero);
      }

      // Pequeño delay para evitar skips muy rápidos
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      print('[AudioPlayer] Error in skipToPrevious: $e');
    } finally {
      _isSkipping = false;
    }
  }

  /// Reproducir una canción específica de la playlist actual
  Future<void> playSong(Song song) async {
    _playlist.selectSong(song);
    await _playCurrentSong();
  }

  // --- Internals ---

  Future<bool> _playCurrentSong({
    bool playNow = true,
    bool addToHistory = true,
  }) async {
    var rawSong = _playlist.currentSong;
    if (rawSong == null) return false;

    // Hidratar metadatos desde caché o archivo si es necesario
    if (rawSong.artworkData == null || rawSong.dominantColor == null) {
      try {
        // 1. Intentar Caché primero
        final cached = await MusicMetadataCache.get(rawSong.id);
        if (cached != null) {
          rawSong = rawSong.copyWith(
            title: cached.title ?? rawSong.title,
            artist: cached.artist ?? rawSong.artist,
            album: cached.album ?? rawSong.album,
            artworkData: cached.artwork ?? rawSong.artworkData,
            dominantColor: cached.dominantColor ?? rawSong.dominantColor,
          );
        } else if (rawSong.artworkData == null) {
          // Solo cargar de archivo si REALMENTE falta el artwork (evita recarga lenta por solo color)
          // 2. Cargar metadatos del archivo (tags reales)
          String? finalTitle;
          String? finalArtist;
          String? finalAlbum;
          Uint8List? finalArtwork;

          if (rawSong.filePath.startsWith('content://')) {
            // Usar SafHelper para archivos SAF
            final metadata = await SafHelper.getMetadataFromUri(
              rawSong.filePath,
            );
            if (metadata != null) {
              finalTitle = (metadata['title'] as String?)?.trim();
              finalArtist = (metadata['artist'] as String?)?.trim();
              finalAlbum = metadata['album'] as String?;
              finalArtwork = metadata['artworkData'] as Uint8List?;
            }
          } else {
            // Usar AudioTags para archivos locales
            final metadataSong = await rawSong.loadMetadata();
            finalTitle = metadataSong.title;
            finalArtist = metadataSong.artist;
            finalAlbum = metadataSong.album;
            finalArtwork = metadataSong.artworkData;
          }

          rawSong = rawSong.copyWith(
            title: (finalTitle != null && finalTitle.isNotEmpty)
                ? finalTitle
                : rawSong.title,
            artist: (finalArtist != null && finalArtist.isNotEmpty)
                ? finalArtist
                : rawSong.artist,
            album: finalAlbum ?? rawSong.album,
            artworkData: finalArtwork,
          );

          // Guardar en caché para futuro
          MusicMetadataCache.saveFromMetadata(
            key: rawSong.id,
            title: rawSong.title,
            artist: rawSong.artist,
            album: rawSong.album,
            durationMs: rawSong.duration?.inMilliseconds,
            artworkData: rawSong.artworkData,
          );
        }
        _playlist.updateCurrentSong(rawSong);
      } catch (e) {
        print("[AudioPlayer] Error hydrating metadata: $e");
      }
    }

    final Song song = rawSong!;

    try {
      _currentSongSubject.add(song);

      // Pre-fetch lyrics for current song
      // No await, we want this in background
      LyricsService().setCurrentSong(song.title, song.artist);

      _history.add(song.id); // Historial de sesión (playback)

      if (addToHistory) {
        await MusicHistoryService().addToHistory(song); // Historial persistente
      }

      // Cargar archivo
      if (song.filePath.startsWith('content://') ||
          song.filePath.startsWith('http')) {
        // Usar AudioSource para URIs (SAF o Web)
        await _audioPlayer.setAudioSource(
          AudioSource.uri(Uri.parse(song.filePath)),
        );
      } else {
        // Archivo local normal
        await _audioPlayer.setFilePath(song.filePath);
      }

      // NO usar await aquí, ya que play() espera hasta que termine la canción
      if (playNow) {
        _audioPlayer.play();
      }

      _playlistSubject.add(_playlist); // Actualizar UI
      return true;
    } catch (e) {
      print('[AudioPlayer] Error playing song: $e');
      return false;
    }
  }

  void _onSongCompleted() async {
    // Lógica automática al terminar canción
    if (_playlist.repeatMode == app_state.RepeatMode.one) {
      await seek(Duration.zero);
      await play();
    } else {
      await skipToNext();
    }
  }

  app_state.PlayerState _mapToAppPlayerState(PlayerState state) {
    final processingState = state.processingState;
    switch (processingState) {
      case ProcessingState.idle:
        return app_state.PlayerState.idle;
      case ProcessingState.loading:
        return app_state.PlayerState.loading;
      case ProcessingState.buffering:
        return app_state.PlayerState.buffering;
      case ProcessingState.ready:
        return state.playing
            ? app_state.PlayerState.playing
            : app_state.PlayerState.paused;
      case ProcessingState.completed:
        return app_state.PlayerState.completed;
    }
  }

  void dispose() {
    _audioPlayer.dispose();
    _playlistSubject.close();
    _currentSongSubject.close();
  }
}
