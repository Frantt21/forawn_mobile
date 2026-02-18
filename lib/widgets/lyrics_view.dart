import 'dart:async';
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

  // Usamos ValueNotifier para solo reconstruir cuando cambia la LÍNEA activa,
  // no cada milisegundo que cambia el progreso de la canción.
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(-1);
  StreamSubscription? _progressSubscription;

  // Cache para evitar iterar la lista completa en cada frame de audio
  bool _firstEvent = true;

  late Stream<PlaybackProgress> _broadcastStream;

  @override
  void initState() {
    super.initState();
    _broadcastStream = widget.progressStream.asBroadcastStream();
    _subscribeToProgress();
  }

  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progressStream != oldWidget.progressStream) {
      _broadcastStream = widget.progressStream.asBroadcastStream();
      _subscribeToProgress();
    }
    // Si cambian las lyrics, resetear
    if (widget.lyrics != oldWidget.lyrics) {
      _currentIndexNotifier.value = -1;
      _firstEvent = true;
      // Forzar chequeo inmediato
    }
  }

  void _subscribeToProgress() {
    _progressSubscription?.cancel();
    _progressSubscription = _broadcastStream.listen((progress) {
      if (widget.lyrics == null || widget.lyrics!.syncedLyrics.isEmpty) return;

      final newIndex = _getLyricIndex(progress.position);

      if (_firstEvent) {
        _currentIndexNotifier.value = newIndex;
        _firstEvent = false;
        // No animar en la primera carga, el builder usará initialScrollIndex
        return;
      }

      if (newIndex != _currentIndexNotifier.value) {
        _currentIndexNotifier.value = newIndex;
        _scrollToIndex(newIndex);
      }
    });
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _currentIndexNotifier.dispose();
    super.dispose();
  }

  void _scrollToIndex(int index) {
    if (!_itemScrollController.isAttached) return;

    // Adjust for phantom line: index -1 -> scroll to 0 (phantom), index 0+ -> scroll to index+1
    final targetIndex = index >= 0 ? index + 1 : 0;

    // Calcular alineación dinámica
    final alignment = _getAlignment(targetIndex);

    _itemScrollController.scrollTo(
      index: targetIndex,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOutCubic,
      alignment: alignment,
    );
  }

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
      return SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Text(
          widget.lyrics!.plainLyrics,
          style: TextStyle(color: widget.textColor, fontSize: 18, height: 1.5),
          textAlign: TextAlign.start,
        ),
      );
    }

    // Solo reconstruimos la lista cuando cambia el índice activo
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndexNotifier,
      builder: (context, currentIndex, _) {
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
            // Initial scroll
            initialScrollIndex: currentIndex >= 0 ? currentIndex + 1 : 0,
            initialAlignment: _getAlignment(
              currentIndex >= 0 ? currentIndex + 1 : 0,
            ),

            itemCount:
                widget.lyrics!.syncedLyrics.length +
                2, // +1 phantom, +1 credits
            itemScrollController: _itemScrollController,
            itemPositionsListener: _itemPositionsListener,
            padding: EdgeInsets.only(
              top: 0, // Phantom line now provides the space
              bottom: MediaQuery.of(context).size.height / 2.5,
            ),
            itemBuilder: (context, index) {
              // Index 0: Phantom line (invisible spacer, always "active")
              if (index == 0) {
                return Container(
                  height: 60, // Match the old top padding
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 24,
                  ),
                  child: Text(
                    '', // Empty text
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                      color: widget.textColor.withOpacity(0), // Invisible
                    ),
                  ),
                );
              }

              // Last item: Credits
              if (index == widget.lyrics!.syncedLyrics.length + 1) {
                return Padding(
                  padding: const EdgeInsets.only(top: 40, bottom: 80),
                  child: Center(
                    child: Text(
                      'Lyrics provided by LRCLIB',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.5),
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                );
              }

              // Real lyrics (index 1 to length)
              final lyricIndex = index - 1; // Adjust for phantom line
              final line = widget.lyrics!.syncedLyrics[lyricIndex];
              final isCurrent = lyricIndex == currentIndex;

              // Calculate end time
              Duration endTime;
              if (lyricIndex < widget.lyrics!.syncedLyrics.length - 1) {
                endTime = widget.lyrics!.syncedLyrics[lyricIndex + 1].timestamp;
              } else {
                // Last line: use song duration or a default 5s buffer
                final durationSec = widget.lyrics!.duration;
                if (durationSec != null) {
                  final songDuration = Duration(seconds: durationSec);
                  endTime = songDuration > line.timestamp
                      ? songDuration
                      : line.timestamp + const Duration(seconds: 5);
                } else {
                  endTime = line.timestamp + const Duration(seconds: 5);
                }
              }

              return GestureDetector(
                onTap: () {
                  // Apply offset to seek position so it matches the synchronized time
                  final seekPosition = line.timestamp + widget.offset;
                  widget.onSeek(seekPosition);
                },
                behavior: HitTestBehavior.opaque, // Mejora touch
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12, // Más espacio para touch
                    horizontal: 24,
                  ),
                  child: _KaraokeLine(
                    text: line.text,
                    isCurrent: isCurrent,
                    startTime: line.timestamp,
                    endTime: endTime,
                    progressStream: _broadcastStream,
                    offset: widget.offset,
                    textColor: widget.textColor,
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
    final targetTime = position - widget.offset; // Ajustar por offset

    // Optimización: Empezar a buscar desde el último índice conocido (o un poco antes por si hizo seek atrás)
    // Pero para seguridad simple en listas cortas (<100 líneas), búsqueda lineal está bien.
    // Si queremos optimizar CPU, podriamos usar búsqueda binaria o incremental.
    // Vamos a hacer búsqueda simple pero robusta.

    for (int i = 0; i < lyrics.length; i++) {
      // Si esta línea es futura, la anterior era la actual
      if (lyrics[i].timestamp > targetTime) {
        return i > 0 ? i - 1 : -1;
      }
    }
    // Si llegamos al final, es la última línea
    return lyrics.length - 1;
  }

  double _getAlignment(int index) {
    return 0.1;
  }
}

class _KaraokeLine extends StatelessWidget {
  final String text;
  final bool isCurrent;
  final Duration startTime;
  final Duration endTime;
  final Stream<PlaybackProgress> progressStream;
  final Duration offset;
  final Color textColor;

  const _KaraokeLine({
    super.key,
    required this.text,
    required this.isCurrent,
    required this.startTime,
    required this.endTime,
    required this.progressStream,
    required this.offset,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    // Estilo base constante para evitar saltos de línea por re-layout
    const baseStyle = TextStyle(
      fontSize: 26, // Un tamaño intermedio fijo
      fontWeight: FontWeight.bold,
      height: 1.3,
      fontFamily: 'Roboto',
    );

    // Dividir texto en palabras para animación granular
    final words = text.split(' ');
    // Calcular longitud total excluyendo espacios para distribución de tiempo
    // (Asumimos que el tiempo se distribuye proporcionalmente a la longitud de los caracteres)
    final totalChars = text.replaceAll(' ', '').length;
    final totalDurationMs = (endTime - startTime).inMilliseconds;

    return AnimatedScale(
      scale: isCurrent ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutQuad,
      alignment: Alignment.centerLeft,
      child: !isCurrent
          ? Container(
              width: double.infinity,
              child: Text(
                text,
                style: baseStyle.copyWith(
                  color: textColor.withOpacity(0.2),
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.left,
              ),
            )
          : Container(
              width: double.infinity,
              child: _buildActiveKaraoke(
                baseStyle,
                totalDurationMs,
                totalChars,
                words,
              ),
            ),
    );
  }

  Widget _buildActiveKaraoke(
    TextStyle textStyle,
    int totalDurationMs,
    int totalChars,
    List<String> words,
  ) {
    return StreamBuilder<PlaybackProgress>(
      stream: progressStream,
      builder: (context, snapshot) {
        final position = snapshot.data?.position ?? Duration.zero;
        final current = position - offset;

        // Factor de corrección: Terminar la animación al 85% del tiempo total
        // Esto compensa los silencios o música al final de la línea.
        final effectiveDurationMs = totalDurationMs * 0.85;

        // Calcular progreso global de la línea (0.0 a 1.0)
        double lineProgress = 0.0;
        if (current >= endTime) {
          lineProgress = 1.0;
        } else if (current > startTime) {
          final elapsed = (current - startTime).inMilliseconds;
          if (effectiveDurationMs > 0) {
            lineProgress = (elapsed / effectiveDurationMs).clamp(0.0, 1.0);
          }
        }

        // Aplicar curva suave cuadrática para evitar sensación robótica
        // (easeOut)
        lineProgress = 1.0 - (1.0 - lineProgress) * (1.0 - lineProgress);

        // Determinar "char index" actual global
        final currentCharIndex = lineProgress * totalChars;

        List<Widget> wordWidgets = [];
        int charAccumulator = 0;

        for (int i = 0; i < words.length; i++) {
          final word = words[i];
          final wordLen = word.length;

          // Calcular rango de caracteres para esta palabra
          final wordStartChar = charAccumulator;
          final wordEndChar = wordStartChar + wordLen;

          // Calcular progreso local de esta palabra
          double wordProgress = 0.0;

          // Hacemos que la transición sea un poco más suave y se solape ligeramente
          // para evitar que se vea "cortado" entre palabras.
          const overlap = 0.5; // Medio caracter de solapamiento visual

          if (currentCharIndex >= wordEndChar) {
            wordProgress = 1.0;
          } else if (currentCharIndex <= wordStartChar - overlap) {
            wordProgress = 0.0;
          } else {
            // Rango extendido para suavidad
            final localCurrent = currentCharIndex - (wordStartChar - overlap);
            final localTotal = wordLen + overlap;
            wordProgress = (localCurrent / localTotal).clamp(0.0, 1.0);
          }

          wordWidgets.add(
            _KaraokeWord(
              word: word,
              progress: wordProgress,
              style: textStyle,
              activeColor: textColor,
              inactiveColor: textColor.withOpacity(0.3),
            ),
          );

          // Espacio entre palabras (si no es la última)
          if (i < words.length - 1) {
            wordWidgets.add(const SizedBox(width: 8));
          }

          charAccumulator += wordLen;
        }

        return Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4, // Espacio vertical entre líneas si hace wrap
          children: wordWidgets,
        );
      },
    );
  }
}

class _KaraokeWord extends StatelessWidget {
  final String word;
  final double progress;
  final TextStyle style;
  final Color activeColor;
  final Color inactiveColor;

  const _KaraokeWord({
    required this.word,
    required this.progress,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    // Si está lleno o vacío, renderizado simple
    if (progress >= 1.0) {
      return Text(
        word,
        style: style.copyWith(
          color: activeColor,
          shadows: [
            BoxShadow(
              color: activeColor.withOpacity(0.5),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
      );
    } else if (progress <= 0.0) {
      return Text(word, style: style.copyWith(color: inactiveColor));
    }

    // Renderizado con gradiente
    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          colors: [
            activeColor, // Pasado
            activeColor,
            inactiveColor, // Futuro
            inactiveColor,
          ],
          stops: [0.0, progress, progress, 1.0],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          tileMode: TileMode.clamp,
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: Text(
        word,
        style: style.copyWith(
          color: Colors.white, // Base para máscara
          shadows: [
            BoxShadow(
              color: activeColor.withOpacity(
                0.3,
              ), // Sombra más suave mientras se llena
              blurRadius: 8,
            ),
          ],
        ),
      ),
    );
  }
}
