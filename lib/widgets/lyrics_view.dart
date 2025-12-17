// lib/widgets/lyrics_view.dart
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../services/lyrics_service.dart';
import '../models/playback_state.dart';

class LyricsView extends StatefulWidget {
  final Lyrics? lyrics;
  final Stream<PlaybackProgress> progressStream;
  final Function(Duration) onSeek;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.progressStream,
    required this.onSeek,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  int _currentIndex = -1;
  bool _isUserScrolling = false;

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
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return StreamBuilder<PlaybackProgress>(
      stream: widget.progressStream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _updateCurrentLine(snapshot.data!.position);
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
            itemCount: widget.lyrics!.syncedLyrics.length,
            itemScrollController: _itemScrollController,
            itemPositionsListener: _itemPositionsListener,
            padding: EdgeInsets.symmetric(
              vertical: MediaQuery.of(context).size.height / 2.5,
            ),
            itemBuilder: (context, index) {
              final line = widget.lyrics!.syncedLyrics[index];
              final isCurrent = index == _currentIndex;

              return GestureDetector(
                onTap: () {
                  // Seek to line timestamp
                  widget.onSeek(line.timestamp);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 32,
                  ),
                  child: isCurrent
                      ? Text(
                          line.text,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24, // Tamaño fijo legible
                            fontWeight: FontWeight.w500,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        )
                      : Text(
                          line.text,
                          style: TextStyle(
                            fontSize: 24,
                            height: 1.5,
                            // Efecto Blur simulado
                            foreground: Paint()
                              ..color = Colors.white.withOpacity(0.4)
                              ..maskFilter = const MaskFilter.blur(
                                BlurStyle.normal,
                                2.0,
                              ),
                          ),
                          textAlign: TextAlign.center,
                        ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _updateCurrentLine(Duration position) {
    final lyrics = widget.lyrics!.syncedLyrics;
    int newIndex = -1;

    // Encontrar la línea actual
    for (int i = 0; i < lyrics.length; i++) {
      if (lyrics[i].timestamp <= position) {
        newIndex = i;
      } else {
        break;
      }
    }

    if (newIndex != _currentIndex) {
      _currentIndex = newIndex;
      // Auto-scroll si no está scrolleando el usuario (simplificado)
      if (newIndex >= 0 && !_isUserScrolling) {
        _itemScrollController.scrollTo(
          index: newIndex,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
          alignment: 0.5, // Centrado
        );
      }
    }
  }
}
