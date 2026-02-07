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
import 'music_library_service.dart';

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _nextAudioPlayer = AudioPlayer(); // Para crossfade

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

  // Crossfade variables
  bool _isCrossfading = false;

  StreamSubscription? _positionSubscription;
  double _crossfadeDuration = 0.0; // En segundos
  bool _usingPrimaryPlayer =
      true; // true = _audioPlayer, false = _nextAudioPlayer
  final _activePlayerSubject = BehaviorSubject<bool>.seeded(true);

  // Streams
  final _playlistSubject = BehaviorSubject<Playlist>();
  Stream<Playlist> get playlistStream => _playlistSubject.stream;

  final _currentSongSubject = BehaviorSubject<Song?>();
  Stream<Song?> get currentSongStream => _currentSongSubject.stream;
  Song? get currentSong => _playlist.currentSong;

  // Combinar posición y duración para progreso
  Stream<app_state.PlaybackProgress> get progressStream =>
      _activePlayerSubject.switchMap((isPrimary) {
        final player = isPrimary ? _audioPlayer : _nextAudioPlayer;
        return Rx.combineLatest3<
          Duration,
          Duration,
          Duration,
          app_state.PlaybackProgress
        >(
          player.positionStream,
          player.bufferedPositionStream,
          player.durationStream.map((d) => d ?? Duration.zero),
          (position, buffered, duration) => app_state.PlaybackProgress(
            position: position,
            bufferedPosition: buffered,
            duration: duration,
          ),
        );
      });

  // Estado del reproductor mapeado al nuestro
  Stream<app_state.PlayerState> get playerStateStream =>
      _activePlayerSubject.switchMap((isPrimary) {
        final player = isPrimary ? _audioPlayer : _nextAudioPlayer;
        return player.playerStateStream.map(_mapToAppPlayerState).distinct();
      });

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

    // Cargar duración de crossfade
    final prefs = await SharedPreferences.getInstance();
    _crossfadeDuration = prefs.getDouble('crossfade_duration') ?? 0.0;

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

    // Escuchar completado para auto-avance en ambos reproductores
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          _usingPrimaryPlayer) {
        _onSongCompleted();
      }
    });

    _nextAudioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          !_usingPrimaryPlayer) {
        _onSongCompleted();
      }
    });

    // Monitorear posición de ambos reproductores para crossfade
    _audioPlayer.positionStream.listen((position) {
      if (_usingPrimaryPlayer) {
        _savePlaybackPreferences();
        _checkCrossfadeStart(position);
      }
    });

    _nextAudioPlayer.positionStream.listen((position) {
      if (!_usingPrimaryPlayer) {
        _savePlaybackPreferences();
        _checkCrossfadeStart(position);
      }
    });

    // Inicializar streams subjects
    if (!_playlistSubject.hasValue) _playlistSubject.add(_playlist);
    if (!_currentSongSubject.hasValue) _currentSongSubject.add(null);

    // Escuchar actualizaciones de metadatos globales
    MusicLibraryService.onMetadataUpdated.addListener(_onMetadataUpdated);
  }

  void _onMetadataUpdated() {
    final uri = MusicLibraryService.onMetadataUpdated.value;
    if (uri != null) {
      // 1. Verificar si es la canción actual
      final current = _playlist.currentSong;
      if (current != null && current.filePath == uri) {
        print(
          '[AudioPlayer] Metadata update received for current song. Refreshing...',
        );
        refreshCurrentSongMetadata();
      }

      // 2. (Opcional) Podríamos actualizar también otras canciones en la playlist
      // pero por ahora priorizamos la actual para rendimiento.
    }
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
        final position = _getActivePlayer().position.inMilliseconds;
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
      await _getActivePlayer().play();
    }
  }

  Future<void> pause() async => await _getActivePlayer().pause();

  Future<void> stop() async {
    await _audioPlayer.stop();
    await _audioPlayer.seek(Duration.zero);
    await _nextAudioPlayer.stop();
    await _nextAudioPlayer.seek(Duration.zero);
    _usingPrimaryPlayer = true; // Reset al primario
    _activePlayerSubject.add(true);
  }

  Future<void> seek(Duration position) async =>
      await _getActivePlayer().seek(position);

  Duration get currentPosition => _getActivePlayer().position;
  Duration get bufferedPosition => _getActivePlayer().bufferedPosition;
  Stream<Duration?> get durationStream => _getActivePlayer().durationStream;
  app_state.PlayerState get playerState =>
      _mapToAppPlayerState(_getActivePlayer().playerState);

  // Crossfade control
  void setCrossfadeDuration(double seconds) {
    _crossfadeDuration = seconds;
    print('[Crossfade] Duración actualizada a ${seconds}s');
  }
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

    // Si el crossfade ya está en progreso, dejarlo terminar
    if (_isCrossfading) {
      print('[AudioPlayer] Crossfade in progress, letting it finish');
      return;
    }

    _isSkipping = true;
    _cancelCrossfade(); // Cancelar crossfade si está en progreso
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

    // Si el crossfade ya está en progreso, dejarlo terminar
    if (_isCrossfading) {
      print('[AudioPlayer] Crossfade in progress, letting it finish');
      return;
    }

    _isSkipping = true;
    _cancelCrossfade(); // Cancelar crossfade si está en progreso
    try {
      // Si la canción lleva más de 3 segundos, reiniciar
      if (_getActivePlayer().position.inSeconds > 3) {
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
    var currentSong = _playlist.currentSong;
    if (currentSong == null) return false;

    try {
      // 1. UI OPTIMISTA: Notificar inmediatamente con lo que tenemos
      _currentSongSubject.add(currentSong);
      _history.add(currentSong.id); // Historial de sesión (ligero)

      // 2. TAREAS EN SEGUNDO PLANO (Fire and forget)

      // A. Historial persistente (No bloquear reproducción por esto)
      if (addToHistory) {
        MusicHistoryService().addToHistory(currentSong).ignore();
      }

      // B. Letras (Ya estaba optimizado)
      LyricsService().setCurrentSong(currentSong.title, currentSong.artist);

      // 3. PREPARACIÓN DE AUDIO (Lo más crítico para playback)
      // Iniciamos esto ANTES de los metadatos pesados para que suene rápido.
      Future<void>? audioPreparation;
      if (playNow) {
        audioPreparation = _prepareAudioSource(currentSong);
        // Iniciamos la preparación pero no esperamos todavía,
        // aprovechamos el tiempo para ver si hay metadatos rápidos.
      }

      // 4. METADATOS (Carga diferida)
      // Si faltan datos, los buscamos, pero actualizamos la UI después.
      if (currentSong.artworkPath == null && currentSong.artworkUri == null) {
        _loadMetadataInBackground(currentSong).then((updatedSong) {
          if (updatedSong != null) {
            // Si la canción sigue siendo la misma, actualizamos
            if (_playlist.currentSong?.id == updatedSong.id) {
              _playlist.updateCurrentSong(updatedSong);
              _currentSongSubject.add(updatedSong);
              _playlistSubject.add(_playlist);
            }
          }
        }).ignore();
      }

      // Notificar cambio de playlist (índice cambió)
      _playlistSubject.add(_playlist);

      // 5. ESPERAR AUDIO Y REPRODUCIR
      if (playNow && audioPreparation != null) {
        await audioPreparation;
        // Verificar que no hayan cambiado la canción mientras cargábamos
        if (_playlist.currentSong?.id == currentSong.id) {
          _getActivePlayer().play();
        }
      } else if (!playNow) {
        // Si es preload, hacerlo en background completamente
        _prepareAudioSource(currentSong).ignore();
      }

      return true;
    } catch (e) {
      print('[AudioPlayer] Error playing song: $e');
      await stop();
      _playlistSubject.add(_playlist);
      return false;
    }
  }

  // Nuevo helper para cargar metadata sin bloquear
  Future<Song?> _loadMetadataInBackground(Song song) async {
    try {
      // 1. Intentar Caché primero (Rápido)
      final cached = await MusicMetadataCache.get(song.id);
      if (cached != null) {
        return song.copyWith(
          title: cached.title,
          artist: cached.artist,
          album: cached.album ?? song.album,
          artworkPath: cached.artworkPath,
          artworkUri: cached.artworkUri,
          dominantColor: cached.dominantColor ?? song.dominantColor,
        );
      } else {
        // 2. Si no está en caché, usar MetadataService (Lento, I/O)
        final metadata = await MetadataService().loadMetadata(
          id: song.id,
          filePath: song.filePath.startsWith('content://')
              ? null
              : song.filePath,
          safUri: song.filePath.startsWith('content://') ? song.filePath : null,
        );

        if (metadata != null) {
          return song.copyWith(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album ?? song.album,
            artworkPath: metadata.artworkPath,
            artworkUri: metadata.artworkUri,
            dominantColor: metadata.dominantColor ?? song.dominantColor,
          );
        }
      }
    } catch (e) {
      print("[AudioPlayer] Error hydrating metadata background: $e");
    }
    return null;
  }

  Future<void> _prepareAudioSource(Song song) async {
    try {
      final activePlayer = _getActivePlayer();

      if (song.filePath.startsWith('content://')) {
        // Optimización: Intentar acceso directo primero (más rápido)
        // Solo copiar a temp si falla
        try {
          await activePlayer.setAudioSource(
            AudioSource.uri(Uri.parse(song.filePath)),
          );
          print('[AudioPlayer] Using direct SAF access (fast path)');

          // Precachear en background para próximas reproducciones
          _copyToTemp(song.filePath).then((path) {
            if (path != null) {
              print('[AudioPlayer] Background cache created for next time');
            }
          }).ignore();
        } catch (e) {
          // Si falla acceso directo, usar temp file
          print('[AudioPlayer] Direct access failed: $e, using temp file...');
          String? playablePath = await _copyToTemp(song.filePath);

          if (playablePath != null) {
            await activePlayer.setAudioSource(
              AudioSource.uri(Uri.file(playablePath)),
            );
          } else {
            throw Exception('Failed to prepare audio source');
          }
        }
      } else if (song.filePath.startsWith('http')) {
        await activePlayer.setAudioSource(
          AudioSource.uri(Uri.parse(song.filePath)),
        );
      } else {
        // Archivo local normal
        await activePlayer.setAudioSource(
          AudioSource.uri(Uri.file(song.filePath)),
        );
      }

      // Precachear la SIGUIENTE canción en background
      _precacheNextSong();
    } catch (e) {
      print('[AudioPlayer] Error preparing audio source: $e');
      rethrow;
    }
  }

  // Precachear la siguiente canción para transiciones más fluidas
  void _precacheNextSong() {
    final nextSong = _playlist.peekNext();
    if (nextSong != null && nextSong.filePath.startsWith('content://')) {
      _copyToTemp(nextSong.filePath).then((path) {
        if (path != null) {
          print('[AudioPlayer] Next song precached: ${nextSong.title}');
        }
      }).ignore();
    }
  }

  // Helper para copiar a temporal si SAF falla
  Future<String?> _copyToTemp(String uriStr) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final filename = 'safe_play_${uriStr.hashCode}.mp3';
      final destFile = File('${tempDir.path}/$filename');

      // Optimización: Si ya existe, reutilizarlo.
      if (await destFile.exists()) {
        final stats = await destFile.stat();
        // Verificar que no esté vacío o corrupto
        if (stats.size > 1024) {
          // Al menos 1KB
          return destFile.path;
        } else {
          // Archivo corrupto, eliminarlo
          await destFile.delete();
        }
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

  // --- Crossfade Methods ---

  AudioPlayer _getActivePlayer() {
    return _usingPrimaryPlayer ? _audioPlayer : _nextAudioPlayer;
  }

  AudioPlayer _getInactivePlayer() {
    return _usingPrimaryPlayer ? _nextAudioPlayer : _audioPlayer;
  }

  void _checkCrossfadeStart(Duration position) {
    if (_crossfadeDuration <= 0 || _isCrossfading || _isSkipping) return;

    final activePlayer = _getActivePlayer();
    final duration = activePlayer.duration;
    if (duration == null) return;

    // Calcular cuándo iniciar el crossfade
    final crossfadeStartTime =
        duration - Duration(seconds: _crossfadeDuration.toInt());

    // Log de debug cada 5 segundos
    if (position.inSeconds % 5 == 0 && position.inMilliseconds % 1000 < 500) {
      final remaining = duration - position;
      print(
        '[Crossfade] Check: pos=${position.inSeconds}s, dur=${duration.inSeconds}s, remaining=${remaining.inSeconds}s, start=${crossfadeStartTime.inSeconds}s, cfDur=${_crossfadeDuration}s',
      );
    }

    // Si estamos en el punto de inicio del crossfade
    if (position >= crossfadeStartTime && position < duration) {
      print('[Crossfade] ¡Iniciando crossfade ahora!');
      _startCrossfade();
    }
  }

  void _startCrossfade() {
    if (_isCrossfading || _crossfadeDuration <= 0) return;

    // Obtener la siguiente canción
    final nextIndex = _playlist.nextIndex;
    if (nextIndex == null) return; // No hay siguiente canción

    final nextSong = _playlist.songs[nextIndex];

    print('[Crossfade] Iniciando crossfade de ${_crossfadeDuration}s');
    _isCrossfading = true;

    final activePlayer = _getActivePlayer();
    final inactivePlayer = _getInactivePlayer();

    // Pre-cargar y reproducir la siguiente canción en segundo plano
    _preloadNextSong(nextSong, inactivePlayer)
        .then((_) {
          print('[Crossfade] Siguiente canción pre-cargada: ${nextSong.title}');

          // Iniciar reproducción de la siguiente canción con volumen 0
          inactivePlayer.setVolume(0.0);
          inactivePlayer.play();

          // Duración del crossfade en milisegundos
          final crossfadeDurationMs = (_crossfadeDuration * 1000).toInt();
          final steps = 20; // Número de pasos para el fade
          final stepDuration = crossfadeDurationMs ~/ steps;

          // Ejecutar fade gradual
          int currentStep = 0;
          Timer.periodic(Duration(milliseconds: stepDuration), (timer) {
            if (!_isCrossfading) {
              timer.cancel();
              return;
            }

            currentStep++;
            final progress = currentStep / steps;

            print(
              '[Crossfade] Step $currentStep/$steps (${(progress * 100).toStringAsFixed(0)}%)',
            );

            // Fade out del reproductor actual
            final currentVolume = 1.0 - progress;
            activePlayer.setVolume(currentVolume.clamp(0.0, 1.0));

            // Fade in del siguiente reproductor
            final nextVolume = progress;
            inactivePlayer.setVolume(nextVolume.clamp(0.0, 1.0));

            if (currentStep >= steps) {
              timer.cancel();
              print(
                '[Crossfade] Timer completado, intercambiando reproductores...',
              );
              // Actualizar índice de playlist ANTES de intercambiar
              _playlist.setCurrentIndex(nextIndex);

              // Actualizar historial y servicios auxiliares
              _history.add(nextSong.id);
              MusicHistoryService().addToHistory(nextSong);
              LyricsService().setCurrentSong(nextSong.title, nextSong.artist);

              _currentSongSubject.add(nextSong);
              _playlistSubject.add(_playlist);
              // Intercambiar reproductores
              _swapPlayers();
              _isCrossfading = false;
              print(
                '[Crossfade] Crossfade completado. Nueva canción: ${nextSong.title}',
              );
            }
          });
        })
        .catchError((e) {
          print('[Crossfade] Error durante crossfade: $e');
          _isCrossfading = false;
        });
  }

  Future<void> _preloadNextSong(Song song, AudioPlayer player) async {
    try {
      // Preparar la fuente de audio para la siguiente canción
      if (song.filePath.startsWith('content://')) {
        String? playablePath;
        try {
          playablePath = await _copyToTemp(song.filePath);
        } catch (e) {
          print('[Crossfade] Pre-cache failed: $e');
        }

        if (playablePath != null) {
          await player.setAudioSource(AudioSource.uri(Uri.file(playablePath)));
        } else {
          await player.setAudioSource(
            AudioSource.uri(Uri.parse(song.filePath)),
          );
        }
      } else if (song.filePath.startsWith('http')) {
        await player.setAudioSource(AudioSource.uri(Uri.parse(song.filePath)));
      } else {
        await player.setAudioSource(AudioSource.uri(Uri.file(song.filePath)));
      }
      print('[Crossfade] Siguiente canción pre-cargada: ${song.title}');
    } catch (e) {
      print('[Crossfade] Error pre-cargando siguiente canción: $e');
      rethrow;
    }
  }

  void _swapPlayers() {
    // Alternar el flag de reproductor activo
    _usingPrimaryPlayer = !_usingPrimaryPlayer;
    _activePlayerSubject.add(_usingPrimaryPlayer);

    // Detener y restaurar volumen del reproductor que ya no está activo
    final inactivePlayer = _getInactivePlayer();
    inactivePlayer.stop();
    inactivePlayer.setVolume(1.0);

    // Asegurar que el reproductor activo está a volumen completo
    final activePlayer = _getActivePlayer();
    activePlayer.setVolume(1.0);

    print(
      '[Crossfade] Reproductores intercambiados. Activo: ${_usingPrimaryPlayer ? "primary" : "secondary"}',
    );
  }

  void _cancelCrossfade() {
    if (_isCrossfading) {
      print('[Crossfade] Cancelando crossfade');
      _isCrossfading = false; // Esto hará que el loop se detenga

      // Restaurar volúmenes de ambos reproductores
      _audioPlayer.setVolume(1.0);
      _nextAudioPlayer.setVolume(1.0);

      // Detener el reproductor inactivo
      _getInactivePlayer().stop();
    }
  }

  void _onSongCompleted() async {
    final activePlayer = _getActivePlayer();
    final position = activePlayer.position;
    final duration = activePlayer.duration;
    print(
      '[AudioPlayer] Canción completada. Pos: ${position.inSeconds}s, Dur: ${duration?.inSeconds}s, Crossfading: $_isCrossfading, Active: ${_usingPrimaryPlayer ? "primary" : "secondary"}',
    );

    // Si el crossfade ya manejó la transición, no hacer nada
    if (_isCrossfading) {
      print('[AudioPlayer] Canción completada durante crossfade, ignorando');
      return;
    }

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
    _cancelCrossfade();
    _positionSubscription?.cancel();
    _audioPlayer.dispose();
    _nextAudioPlayer.dispose();
    _playlistSubject.close();
    _currentSongSubject.close();
  }
}
