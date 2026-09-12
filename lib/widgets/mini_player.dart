// lib/widgets/mini_player.dart
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart';
import '../screens/music_player_screen.dart';
import '../widgets/artwork_widget.dart';

/// Navigator global: el miniplayer vive en MaterialApp.builder, FUERA del
/// Navigator, así que Navigator.of(context) no encuentra Navigator
/// ("operation requested with a context that does not include a Navigator").
/// Sus pushes usan esta key, igual que Forawn desktop.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Controla qué capas tapan al miniplayer persistente.
/// Los diálogos/bottom-sheets lo tapan automáticamente vía MiniPlayerNavObserver.
class MiniCoverService {
  MiniCoverService._();
  static final MiniCoverService instance = MiniCoverService._();

  int _count = 0;
  final ValueNotifier<int> _covers = ValueNotifier<int>(0);
  bool _notifyScheduled = false;

  void pushCover() {
    _count++;
    _scheduleNotify();
  }

  void popCover() {
    if (_count > 0) _count--;
    _scheduleNotify();
  }

  /// La notificación se difiere a post-frame: pushCover puede correr
  /// durante la fase de build (instalación de rutas) y notificar en ese
  /// momento lanza "markNeedsBuild called during build", que ROMPE la
  /// actualización del host.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      _covers.value = _count;
    });
  }
}

/// Visibilidad del miniplayer. Solo se muestra en el screen de música
/// (LocalMusicScreen) y en las playlists (PlaylistDetailScreen): lo marcan
/// con [pushScreen]/[popScreen]. Nunca se ve sobre el reproductor completo
/// ([fullPlayerOpen]).
class MiniPlayerVisibility {
  MiniPlayerVisibility._();
  static final MiniPlayerVisibility instance = MiniPlayerVisibility._();

  /// Screens apilados que admiten el miniplayer. Se usa un Set y no un
  /// bool porque las rutas se apilan (LocalMusic -> PlaylistDetail): al
  /// cerrar la de arriba, la de abajo sigue activa aunque su initState
  /// no se vuelva a ejecutar.
  final Set<String> _activeScreens = <String>{};

  /// true cuando el screen activo es uno que admite el miniplayer.
  final ValueNotifier<bool> screenActive = ValueNotifier<bool>(false);

  /// true mientras está abierto el reproductor completo (MusicPlayerScreen).
  final ValueNotifier<bool> fullPlayerOpen = ValueNotifier<bool>(false);

  /// true mientras el splash inicial está visible.
  final ValueNotifier<bool> splashActive = ValueNotifier<bool>(false);

  void pushScreen(String id) {
    _activeScreens.add(id);
    _scheduleScreenUpdate('pushScreen($id)');
  }

  void popScreen(String id) {
    _activeScreens.remove(id);
    _scheduleScreenUpdate('popScreen($id)');
  }

  bool _screenNotifyScheduled = false;

  /// CRÍTICO: pushScreen se llama desde initState de screens que se montan
  /// DURANTE la fase de build. Asignar screenActive.value ahí notifica al
  /// host en pleno build → "markNeedsBuild called during build" → la
  /// reconstrucción se pierde y el miniplayer nunca aparece. Se difiere la
  /// asignación a post-frame (coalescida: múltiples push/pop en el mismo
  /// frame aplican un solo update con el estado final).
  void _scheduleScreenUpdate(String origin) {
    if (_screenNotifyScheduled) return;
    _screenNotifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _screenNotifyScheduled = false;
      final active = _activeScreens.isNotEmpty;
      if (kDebugMode) {
        debugPrint(
          '[MiniPlayerVisibility] $origin -> active=$active (deferred), '
          'instance=${identityHashCode(this)}, screens=$_activeScreens',
        );
      }
      screenActive.value = active;
    });
  }

  void setFullPlayerOpen(bool value) {
    if (fullPlayerOpen.value == value) return;
    // setFullPlayerOpen corre en initState de MusicPlayerScreen (también
    // durante build): mismo riesgo → difierir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      fullPlayerOpen.value = value;
    });
  }

  void setSplashActive(bool value) {
    if (splashActive.value == value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      splashActive.value = value;
    });
  }
}

/// Observador que tapa el miniplayer mientras hay diálogos/rutas modales
/// abiertas.
class MiniPlayerNavObserver extends NavigatorObserver {
  bool _isOpaqueModal(Route<dynamic> route) {
    if (route is PopupRoute) return true;
    return route is ModalRoute<dynamic> && route.fullscreenDialog;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOpaqueModal(route)) MiniCoverService.instance.pushCover();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOpaqueModal(route)) MiniCoverService.instance.popCover();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOpaqueModal(route)) MiniCoverService.instance.popCover();
  }
}

/// Host del miniplayer persistente: se monta UNA sola vez en
/// MaterialApp.builder, sobre todas las rutas. La visibilidad depende de:
///  - [MiniPlayerVisibility.screenActive]: solo LocalMusicScreen y
///    PlaylistDetailScreen muestran el miniplayer.
///  - [MiniPlayerVisibility.fullPlayerOpen]: el reproductor completo lo esconde.
///  - [MiniCoverService] covers: el splash y los diálogos lo esconden.
/// Entra/sale con la animación de Forawn desktop (slide + fade + easeOutCubic).
class MiniPlayerHost extends StatelessWidget {
  const MiniPlayerHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MiniPlayerVisibility.instance.screenActive,
      builder: (context, screenActive, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: MiniPlayerVisibility.instance.fullPlayerOpen,
          builder: (context, fullPlayerOpen, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: MiniPlayerVisibility.instance.splashActive,
              builder: (context, splashActive, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: MiniCoverService.instance._covers,
                  builder: (context, covers, _) {
                    final visible =
                        screenActive &&
                        !fullPlayerOpen &&
                        !splashActive &&
                        covers == 0;
                    if (kDebugMode) {
                      debugPrint(
                        '[MiniPlayerHost#${identityHashCode(this)}] visible=$visible '
                        '(screenActive=$screenActive, '
                        'fullPlayerOpen=$fullPlayerOpen, '
                        'splashActive=$splashActive, covers=$covers, '
                        'visInstance=${identityHashCode(MiniPlayerVisibility.instance)})',
                      );
                    }
                    final hideDuration = fullPlayerOpen
                        ? const Duration(milliseconds: 450)
                        : const Duration(milliseconds: 200);
                    return ClipRect(
                      child: AnimatedSlide(
                        offset: visible ? Offset.zero : const Offset(0, 1.1),
                        duration: visible
                            ? const Duration(milliseconds: 450)
                            : hideDuration,
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: visible ? 1.0 : 0.0,
                          duration: visible
                              ? const Duration(milliseconds: 450)
                              : hideDuration,
                          curve: Curves.easeOutCubic,
                          child: IgnorePointer(
                            ignoring: !visible,
                            // El host vive en MaterialApp.builder, FUERA de
                            // todo Material/Scaffold. Sin ancestro Material,
                            // los Text heredan el DefaultTextStyle de fallback
                            // (subrayado amarillo). MaterialType.transparency
                            // pinta la tipografía correcta sin añadir fondo.
                            child: Material(
                              type: MaterialType.transparency,
                              child: SafeArea(child: MiniPlayer()),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

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
          // Detectar arrastre horizontal para cambiar de canción
          onHorizontalDragEnd: song != null
              ? (details) {
                  // Deslizamiento rápido (fling)
                  if (details.primaryVelocity! > 0) {
                    // Deslizar a derecha -> Anterior
                    player.skipToPrevious();
                  } else if (details.primaryVelocity! < 0) {
                    // Deslizar a izquierda -> Siguiente
                    player.skipToNext();
                  }
                }
              : null,
          // Detectar arrastre vertical
          onVerticalDragUpdate: song != null
              ? (details) {
                  // Si arrastra hacia arriba (delta negativo), abrir reproductor
                  if (details.primaryDelta! < -5) {
                    appNavigatorKey.currentState?.push(
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
                  appNavigatorKey.currentState?.push(
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
                      ? StreamBuilder<PlaybackProgress>(
                          stream: player.progressStream,
                          builder: (context, progressSnapshot) {
                            final progress = progressSnapshot.data;
                            final progressPercent =
                                progress != null &&
                                    progress.duration.inMilliseconds > 0
                                ? progress.position.inMilliseconds /
                                      progress.duration.inMilliseconds
                                : 0.0;

                            return Stack(
                              children: [
                                // Progress background layer
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: progressPercent.clamp(
                                          0.0,
                                          1.0,
                                        ),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.05,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Content on top
                                _buildPlayerContent(song, player),
                              ],
                            );
                          },
                        )
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
                  child: ArtworkWidget(
                    key: ValueKey(song.id),
                    artworkPath: song.artworkPath,
                    artworkUri: song.artworkUri,
                    width: null, // Let it use size
                    height: null,
                    size:
                        55, // Explicit size for caching optimization (~70 container - 16 padding)
                    fit: BoxFit.cover,
                    dominantColor: song.dominantColor,
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
