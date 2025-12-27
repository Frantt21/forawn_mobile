// lib/widgets/lyrics_view.dart
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../services/lyrics_service.dart';
import '../models/playback_state.dart';

class LyricsView extends StatefulWidget {
  final Lyrics? lyrics;
  final Stream<PlaybackProgress> progressStream;
  final Function(Duration) onSeek;
  final Duration offset;
  final Color textColor;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.progressStream,
    required this.onSeek,
    this.offset = Duration.zero,
    this.textColor = Colors.white,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  int _currentIndex = -1;
  int? _initialIndex; // Para controlar el scroll inicial sin animación
  final bool _isUserScrolling = false;

  @override
  Widget build(BuildContext context) {
    if (widget.lyrics == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('Buscando letras...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    if (widget.lyrics!.syncedLyrics.isEmpty) {
      // Mostrar letras planas si no hay sincronizadas
      return SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Text(
          widget.lyrics!.plainLyrics,
          style: TextStyle(color: widget.textColor, fontSize: 18, height: 1.5),
          textAlign: TextAlign.start,
        ),
      );
    }

    return StreamBuilder<PlaybackProgress>(
      stream: widget.progressStream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final newIndex = _getLyricIndex(snapshot.data!.position);

          // Primera carga: Establecer initialIndex y currentIndex sin animación
          if (_initialIndex == null) {
            _initialIndex = newIndex < 0
                ? 0
                : newIndex; // Asegurar índice válido para scroll
            _currentIndex = newIndex;
          } else {
            // Actualizaciones subsiguientes: Animar si cambia
            _updateCurrentLine(newIndex);
          }
        } else if (_initialIndex == null) {
          // Aún no hay datos de posición, esperar
          return const SizedBox();
        }

        return ShaderMask(
          shaderCallback: (rect) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.1, 0.9, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: ScrollablePositionedList.builder(
            initialScrollIndex: _initialIndex ?? 0,
            initialAlignment: _getAlignment(
              _initialIndex ?? 0,
            ), // Alinear correctamente al inicio
            itemCount: widget.lyrics!.syncedLyrics.length,
            itemScrollController: _itemScrollController,
            itemPositionsListener: _itemPositionsListener,
            padding: EdgeInsets.only(
              top: 60,
              bottom: MediaQuery.of(context).size.height / 2.5,
            ),
            itemBuilder: (context, index) {
              final line = widget.lyrics!.syncedLyrics[index];
              final isCurrent = index == _currentIndex;

              return GestureDetector(
                onTap: () {
                  // Seek to line timestamp (adjusted by offset logic inverse?)
                  // Seek debería ir al timestamp original
                  widget.onSeek(line.timestamp);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 24, // Padding lateral ajustado
                  ),
                  child: isCurrent
                      ? Text(
                          line.text,
                          style: TextStyle(
                            color: widget.textColor,
                            fontSize: 24, // Mismo tamaño que inactivo
                            fontWeight: FontWeight.bold,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.start, // Alineado izquierda
                        )
                      : Text(
                          line.text,
                          style: TextStyle(
                            fontSize: 24,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                            // Efecto Blur simulado
                            foreground: Paint()
                              ..color = widget.textColor.withOpacity(0.4)
                              ..maskFilter = const MaskFilter.blur(
                                BlurStyle.normal,
                                1.0,
                              ),
                          ),
                          textAlign: TextAlign.start,
                        ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  int _getLyricIndex(Duration position) {
    final lyrics = widget.lyrics!.syncedLyrics;
    int index = -1;
    for (int i = 0; i < lyrics.length; i++) {
      if ((lyrics[i].timestamp + widget.offset) <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _updateCurrentLine(int newIndex) {
    if (newIndex != _currentIndex) {
      _currentIndex = newIndex;
      // Auto-scroll si no está scrolleando el usuario
      if (newIndex >= 0 && !_isUserScrolling) {
        // Calcular alineación dinámica
        final alignment = _getAlignment(newIndex);

        // Verificar si el controlador está adjunto antes de llamar
        if (_itemScrollController.isAttached) {
          _itemScrollController.scrollTo(
            index: newIndex,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
            alignment: alignment,
          );
        }
      }
    }
  }

  double _getAlignment(int index) {
    if (index < 5) {
      // De 0.1 (Top) a 0.5 (Middle)
      return 0.1 + (index / 5.0) * 0.4;
    }
    return 0.5; // Centrado
  }
}
