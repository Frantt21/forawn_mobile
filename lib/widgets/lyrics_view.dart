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


  List<LyricLine> _processedLyrics = [];
  Lyrics? _lastLyrics;

  List<LyricLine> get _activeLyrics {
    if (widget.lyrics == null) return [];

    if (_lastLyrics != widget.lyrics) {
      _lastLyrics = widget.lyrics;
      _processedLyrics = _computeLyricsWithGaps(widget.lyrics!.syncedLyrics);
    }
    return _processedLyrics;
  }

  List<LyricLine> _computeLyricsWithGaps(List<LyricLine> original) {
    if (original.isEmpty) return [];

    final List<LyricLine> result = [];
    // Espacio instrumental muy largo al inicio de la canción
    if (original.first.timestamp.inSeconds > 10) {
      result.add(LyricLine(timestamp: Duration.zero, text: '•••'));
    }

    for (int i = 0; i < original.length; i++) {
      final current = original[i];
      result.add(current);

      if (i < original.length - 1) {
        final next = original[i + 1];

        // Calcular cuánto tiempo aproximado le toma cantar esta línea
        final chars = current.text.length;
        int estimatedMs =
            ((chars / 12.0) * 1000).toInt() + 1500; // 1.5s de respiro

        final durationUntilNext =
            (next.timestamp - current.timestamp).inMilliseconds;

        // Limitamos la estimación a no invadir el tiempo de la próxima línea
        if (estimatedMs > durationUntilNext - 1000) {
          estimatedMs = durationUntilNext - 1000;
        }

        final currentEndApprox =
            current.timestamp + Duration(milliseconds: estimatedMs);

        // Si quedan más de 8 segundos hasta el inicio de la siguiente vocal
        if (next.timestamp - currentEndApprox > const Duration(seconds: 8)) {
          result.add(LyricLine(timestamp: currentEndApprox, text: '•••'));
        }
      }
    }
    return result;
  }

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

        // Corregir el salto al inicio al abrir el modal:
        // Forzamos el salto a la línea correcta en cuanto recibimos el evento de inicio.
        Timer(const Duration(milliseconds: 100), () {
          if (mounted && _itemScrollController.isAttached) {
            final targetIndex = newIndex >= 0 ? newIndex + 1 : 0;
            _itemScrollController.jumpTo(
              index: targetIndex,
              alignment: _getAlignment(targetIndex),
            );
          }
        });
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

    if (_activeLyrics.isEmpty) {
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
        return Stack(
          children: [
            ShaderMask(
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

                itemCount: _activeLyrics.length + 2, // +1 phantom, +1 credits
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

                  // Last item: Credits (nombre real del proveedor)
                  if (index == _activeLyrics.length + 1) {
                    final provider = widget.lyrics!.source ?? 'LRCLIB';
                    return Padding(
                      padding: const EdgeInsets.only(top: 40, bottom: 80),
                      child: Center(
                        child: Text(
                          'Lyrics provided by $provider',
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
                  final line = _activeLyrics[lyricIndex];
                  final isCurrent = lyricIndex == currentIndex;

                  // Calculate end time
                  Duration endTime;
                  if (lyricIndex < _activeLyrics.length - 1) {
                    endTime = _activeLyrics[lyricIndex + 1].timestamp;
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
                        isSweepEnabled: true,
                        tagWords: line.words,
                      ),
                    ),
                  );
                },
              ),
            ),
            // Pill con el proveedor de las letras (KPoe / LRCLIB / lyrics.ovh)
            if (widget.lyrics!.source != null &&
                widget.lyrics!.source!.trim().isNotEmpty)
              Positioned(
                top: 8,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.15),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    widget.lyrics!.source!,
                    style: TextStyle(
                      color: widget.textColor.withOpacity(0.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  int _getLyricIndex(Duration position) {
    final lyrics = _activeLyrics;
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
  final bool isSweepEnabled;
  final List<KaraokeWord>? tagWords;

  const _KaraokeLine({
    super.key,
    required this.text,
    required this.isCurrent,
    required this.startTime,
    required this.endTime,
    required this.progressStream,
    required this.offset,
    required this.textColor,
    this.isSweepEnabled = true,
    this.tagWords,
  });

  @override
  Widget build(BuildContext context) {
    // Estilo base constante para evitar saltos de línea por re-layout
    const baseStyle = TextStyle(
      fontSize: 34, // Tamaño de letra ampliado a petición del usuario
      fontWeight: FontWeight.bold,
      height: 1.3,
      fontFamily: 'Roboto',
    );

    // Dividir texto en palabras para el layout estático (mismo Wrap que la
    // línea activa para que el salto de línea no se mueva). Split por
    // whitespace (no solo espacio) para ignorar dobles espacios residuales.
    final words = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    // Calculamos el layout constante para ambas (activa e inactiva)
    // Usamos Wrap en ambas para que el salto de línea siempre caiga en el mismo lugar exacto.
    List<Widget> staticWordWidgets = [];
    for (int i = 0; i < words.length; i++) {
      staticWordWidgets.add(
        Text(
          words[i] + (i < words.length - 1 ? ' ' : ''),
          style: baseStyle.copyWith(
            color: textColor.withOpacity(0.2),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // Restauramos AnimatedScale conservando la estructura Wrap en ambos estados
    // y sin usar padding extra para arreglar la separación.
    return AnimatedScale(
      scale: isCurrent ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutQuad,
      alignment: Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: !isCurrent
            ? Container(
                key: const ValueKey('inactive'),
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 0.0,
                  runSpacing: 4.0,
                  children: staticWordWidgets,
                ),
              )
            : Container(
                key: const ValueKey('active'),
                width: double.infinity,
                child: isSweepEnabled && (tagWords?.isNotEmpty ?? false)
                    ? _buildActiveKaraoke(baseStyle)
                    : _buildSimpleActiveLine(baseStyle, staticWordWidgets),
              ),
      ),
    );
  }

  /// Línea activa con sweep palabra por palabra usando SOLO los timestamps
  /// reales del proveedor (KPoe/SyncLRC). Sin timestamps no hay sweep.
  Widget _buildActiveKaraoke(TextStyle textStyle) {
    return StreamBuilder<PlaybackProgress>(
      stream: progressStream,
      builder: (context, snapshot) {
        final position = snapshot.data?.position ?? Duration.zero;
        final current = position - offset;

        final wordWidgets = <Widget>[];
        // Normalización de Scrup: cada palabra del proveedor se divide en
        // piezas sin espacios internos (mismo timestamp) para que el layout
        // tenga EXACTAMENTE un espacio entre tokens — arregla palabras tipo
        // 'Han ' (espacio pegado del proveedor o del cache viejo).
        final pieces = <(String, Duration, Duration)>[];
        for (int i = 0; i < tagWords!.length; i++) {
          final w = tagWords![i];
          final wEnd = (i < tagWords!.length - 1)
              ? tagWords![i + 1].timestamp
              : endTime;
          for (final piece in w.text.trim().split(RegExp(r'\s+'))) {
            if (piece.isEmpty) continue;
            pieces.add((piece, w.timestamp, wEnd));
          }
        }
        for (int i = 0; i < pieces.length; i++) {
          final (text, wStart, wEnd) = pieces[i];

          double wordProgress = 0.0;
          if (current >= wEnd) {
            wordProgress = 1.0;
          } else if (current > wStart) {
            final durationMs = (wEnd - wStart).inMilliseconds;
            if (durationMs > 0) {
              wordProgress = ((current - wStart).inMilliseconds / durationMs)
                  .clamp(0.0, 1.0);
            } else {
              wordProgress = 1.0;
            }
          }

          wordWidgets.add(
            _KaraokeWord(
              // Solo añadir espacio si no es la última palabra para mantener el layout general
              word: text + (i < pieces.length - 1 ? ' ' : ''),
              progress: wordProgress,
              style: textStyle,
              activeColor: textColor,
              inactiveColor: textColor.withOpacity(0.3),
            ),
          );
        }

        return Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 0.0,
          runSpacing: 4.0,
          children: wordWidgets,
        );
      },
    );
  }

  Widget _buildSimpleActiveLine(TextStyle textStyle, List<Widget> _) {
    // Generate simple text with active color (split por whitespace para
    // ignorar dobles espacios residuales del proveedor/cache).
    final wordsArray = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    List<Widget> activeWords = [];
    for (int i = 0; i < wordsArray.length; i++) {
      activeWords.add(
        Text(
          wordsArray[i] + (i < wordsArray.length - 1 ? ' ' : ''),
          style: textStyle.copyWith(color: textColor),
        ),
      );
    }
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0.0,
      runSpacing: 4.0,
      children: activeWords,
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
    if (progress >= 1.0) {
      return Text(word, style: style.copyWith(color: activeColor));
    } else if (progress <= 0.0) {
      return Text(word, style: style.copyWith(color: inactiveColor));
    }

    // Acelerador visual de progreso para que la última letra siempre se ilumine por completo
    final visualProgress = (progress * 1.25).clamp(0.0, 1.0);

    // Renderizado con gradiente fluido
    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          colors: [
            activeColor,
            activeColor.withOpacity(
              0.5,
            ), // Transición más amable sin cortes duros
            inactiveColor,
          ],
          stops: [
            (visualProgress - 0.2).clamp(0.0, 1.0),
            visualProgress,
            (visualProgress + 0.2).clamp(0.0, 1.0),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          tileMode: TileMode.clamp,
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: Text(word, style: style.copyWith(color: Colors.white)),
    );
  }
}
