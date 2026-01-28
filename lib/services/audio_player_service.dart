// lib/services/audio_player_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/playback_state.dart'
    as app_state; // Alias para evitar conflicto con just_audio
import 'music_history_service.dart';
import 'music_metadata_cache.dart';
import 'saf_helper.dart';

import 'metadata_service.dart';
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
  // Flag para prevenir bucle de recuperacion
  bool _isRecovering = false;
  // Reproductor de fallback para archivos problemáticos
  ap.AudioPlayer? _fallbackPlayer;
  bool _usingFallback = false;

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
  // Estado del reproductor mapeado al nuestro
  late final Stream<app_state.PlayerState> playerStateStream = _audioPlayer
      .playerStateStream
      .map(_mapToAppPlayerState)
      .distinct();

  Stream<bool> get shuffleModeStream =>
      _playlistSubject.map((p) => p.isShuffle).distinct();

  Stream<app_state.RepeatMode> get repeatModeStream =>
      _playlistSubject.map((p) => p.repeatMode).distinct();

  // Stream para notificar al sistema (AudioHandler) de cualquier cambio relevante
  // (Seek, Buffering, Play/Pause) sin filtrar por distinct()
  Stream<void> get playbackRefreshStream =>
      _audioPlayer.playbackEventStream.map((_) {});

  // Initialization
  Future<void> _init() async {
    // Cargar preferencias guardadas
    await _loadPlaybackPreferences();

    // Configurar sesión de audio
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Escuchar errores y recuperación
    _audioPlayer.playbackEventStream.listen(
      (event) {},
      onError: (Object e, StackTrace stackTrace) {
        print('[AudioPlayer] Playback error stream: $e');
        _handlePlaybackError(e);
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

  Future<void> _handlePlaybackError(Object error) async {
    if (_isRecovering) return;
    _isRecovering = true;

    try {
      final song = _playlist.currentSong;
      if (song != null && song.filePath.startsWith('content://')) {
        print(
          '[AudioPlayer] Playback error detected. Attempting fallback to audioplayers...',
        );

        // Copiar a temp si no está ya copiado
        final tempPath = await _copyToTemp(song.filePath);
        if (tempPath != null) {
          print('[AudioPlayer] Switching to fallback player (audioplayers)');

          // Detener just_audio
          await _audioPlayer.stop();

          // Inicializar fallback player si no existe
          _fallbackPlayer ??= ap.AudioPlayer();
          _usingFallback = true;

          // Configurar y reproducir con audioplayers
          await _fallbackPlayer!.play(ap.DeviceFileSource(tempPath));

          // Escuchar eventos del fallback player
          _fallbackPlayer!.onPlayerComplete.listen((_) {
            _onSongCompleted();
          });

          print('[AudioPlayer] Fallback player started successfully');
          return; // Recuperación exitosa
        }
      }

      // Si llegamos aquí, no se pudo recuperar
      print('[AudioPlayer] Unrecoverable error. Stopping player.');
      await stop();
      if (!_playlistSubject.isClosed) {
        _playlistSubject.add(_playlist);
      }
    } catch (e) {
      print('[AudioPlayer] Error during recovery: $e');
      await stop();
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      _isRecovering = false;
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
  Stream<Duration?> get durationStream => _audioPlayer.durationStream;
  app_state.PlayerState get playerState =>
      _mapToAppPlayerState(_audioPlayer.playerState);

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
    if (rawSong.artworkPath == null && rawSong.artworkUri == null) {
      try {
        // 1. Intentar Caché primero
        final cached = await MusicMetadataCache.get(rawSong.id);
        if (cached != null) {
          rawSong = rawSong.copyWith(
            title: cached.title,
            artist: cached.artist,
            album: cached.album ?? rawSong.album,
            artworkPath: cached.artworkPath,
            artworkUri: cached.artworkUri,
            dominantColor: cached.dominantColor ?? rawSong.dominantColor,
          );
        } else {
          // 2. Si no está en caché, usar MetadataService para cargar y guardar
          // Esto maneja SAF y archivos locales, extrae artwork, guarda en disco y devuelve paths
          final metadata = await MetadataService().loadMetadata(
            id: rawSong.id,
            filePath: rawSong.filePath.startsWith('content://')
                ? null
                : rawSong.filePath,
            safUri: rawSong.filePath.startsWith('content://')
                ? rawSong.filePath
                : null,
          );

          if (metadata != null) {
            rawSong = rawSong.copyWith(
              title: metadata.title,
              artist: metadata.artist,
              album: metadata.album ?? rawSong.album,
              artworkPath: metadata.artworkPath,
              artworkUri: metadata.artworkUri,
              dominantColor: metadata.dominantColor ?? rawSong.dominantColor,
            );
          }
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
      // Cambio estratégico: En Android modernos, el acceso directo a SAF desde código nativo (ExoPlayer)
      // puede causar errores de parsing 'Searched too many bytes' debido a streams mal formados.
      // Solución: Copiar preventivamente a caché local (temp) y reproducir desde archivo físico.
      if (song.filePath.startsWith('content://')) {
        print('[AudioPlayer] Pre-caching content URI for stability...');
        String? playablePath;
        try {
          playablePath = await _copyToTemp(song.filePath);
        } catch (e) {
          print('[AudioPlayer] Pre-cache failed: $e, trying direct access');
        }

        if (playablePath != null) {
          await _audioPlayer.setAudioSource(
            AudioSource.uri(Uri.file(playablePath)),
          );
        } else {
          // Fallback a acceso directo si la copia falla
          await _audioPlayer.setAudioSource(
            AudioSource.uri(Uri.parse(song.filePath)),
          );
        }
      } else if (song.filePath.startsWith('http')) {
        await _audioPlayer.setAudioSource(
          AudioSource.uri(Uri.parse(song.filePath)),
        );
      } else {
        // Archivo local normal
        await _audioPlayer.setAudioSource(
          AudioSource.uri(Uri.file(song.filePath)),
        );
      }

      // NO usar await aquí, ya que play() espera hasta que termine la canción
      if (playNow) {
        _audioPlayer.play();
      }

      _playlistSubject.add(_playlist); // Actualizar UI
      return true;
    } catch (e) {
      print('[AudioPlayer] Error playing song: $e');
      await stop();
      _playlistSubject.add(_playlist);
      return false;
    }
  }

  // Helper para copiar a temporal si SAF falla
  Future<String?> _copyToTemp(String uriStr) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final filename = 'safe_play_${uriStr.hashCode}.mp3';
      final destFile = File('${tempDir.path}/$filename');

      // Limpiar si ya existe
      if (await destFile.exists()) {
        await destFile.delete();
      }

      final success = await SafHelper.copyUriToFile(uriStr, destFile.path);
      if (success && await destFile.exists()) {
        print('[AudioPlayer] Copied content URI to temp: ${destFile.path}');
        return destFile.path;
      }
      return null;
    } catch (e) {
      print('[AudioPlayer] Error copying to temp: $e');
      return null;
    }
  }

  Future<void> refreshCurrentSongMetadata() async {
    final current = _playlist.currentSong;
    if (current == null) return;

    // Forzar carga desde caché (que ya debería estar actualizado al llamar esto)
    final cached = await MusicMetadataCache.get(current.id);
    if (cached != null) {
      // IMPORTANTE: Limpiar el caché de imágenes de Flutter
      // para que se recargue el artwork actualizado
      if (cached.artworkPath != null) {
        final file = File(cached.artworkPath!);
        if (file.existsSync()) {
          // Evict the old image from Flutter's cache
          final fileImage = FileImage(file);
          fileImage.evict();
          print(
            '[AudioPlayer] Evicted image from cache: ${cached.artworkPath}',
          );
        }
      }

      final newSong = current.copyWith(
        title: cached.title ?? current.title,
        artist: cached.artist ?? current.artist,
        album: cached.album ?? current.album,
        artworkPath: cached.artworkPath,
        artworkUri: cached.artworkUri,
        dominantColor: cached.dominantColor ?? current.dominantColor,
      );

      _playlist.updateCurrentSong(newSong);
      _currentSongSubject.add(newSong);
      _playlistSubject.add(_playlist);
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
