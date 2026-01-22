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

  @override
  void initState() {
    super.initState();
    _subscribeToProgress();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progressStream != oldWidget.progressStream) {
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
    _progressSubscription = widget.progressStream.listen((progress) {
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
    if (index >= 0 && !_itemScrollController.isAttached) return;

    // Calcular alineación dinámica
    final alignment = _getAlignment(index);

    _itemScrollController.scrollTo(
      index: index,
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
        // Esperar a tener la primera posición válida para evitar saltos visuales
        if (currentIndex == -1) {
          return const SizedBox.shrink();
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
            // Initial scroll
            initialScrollIndex: currentIndex > 0 ? currentIndex : 0,
            initialAlignment: _getAlignment(
              currentIndex > 0 ? currentIndex : 0,
            ),

            itemCount: widget.lyrics!.syncedLyrics.length,
            itemScrollController: _itemScrollController,
            itemPositionsListener: _itemPositionsListener,
            padding: EdgeInsets.only(
              top: 60,
              bottom: MediaQuery.of(context).size.height / 2.5,
            ),
            itemBuilder: (context, index) {
              final line = widget.lyrics!.syncedLyrics[index];
              final isCurrent = index == currentIndex;

              return GestureDetector(
                onTap: () => widget.onSeek(line.timestamp),
                behavior: HitTestBehavior.opaque, // Mejora touch
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12, // Más espacio para touch
                    horizontal: 24,
                  ),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                      color: isCurrent
                          ? widget.textColor
                          : widget.textColor.withOpacity(0.3),
                    ),
                    child: Text(line.text, textAlign: TextAlign.start),
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
        return i > 0 ? i - 1 : 0;
      }
    }
    // Si llegamos al final, es la última línea
    return lyrics.length - 1;
  }

  double _getAlignment(int index) {
    // Transición suave de top a center en las primeras 10 líneas
    // Esto evita el efecto de "estiramiento" visual
    if (index < 10) {
      // Interpolación suave de 0.2 (cerca del top) a 0.5 (centro)
      // Usando una curva easeOut para suavizar la transición
      final progress = index / 10.0;
      final easedProgress = 1 - (1 - progress) * (1 - progress); // easeOut
      return 0.2 + (easedProgress * 0.3); // 0.2 → 0.5
    }
    return 0.5; // Centro para el resto
  }
}
