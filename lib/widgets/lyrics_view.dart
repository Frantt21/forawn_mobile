import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/lyrics_service.dart';
import '../models/playback_state.dart';

class LyricsView extends StatefulWidget {
  final Lyrics? lyrics;
  final Stream<PlaybackProgress> progressStream;
  final Function(Duration) onSeek;
  final Duration offset;
  final Color textColor;
  final String? audioPath;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.progressStream,
    required this.onSeek,
    this.offset = Duration.zero,
    this.textColor = Colors.white,
    this.audioPath,
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

  // Waveform data
  final PlayerController _playerController = PlayerController();
  List<double> _waveformData = [];
  bool _isWaveformLoading = false;

  bool _isSweepEnabled = false;

  List<LyricLine> get _activeLyrics {
    if (widget.lyrics == null) return [];
    return widget.lyrics!.syncedLyrics;
  }

  @override
  void initState() {
    super.initState();
    _broadcastStream = widget.progressStream.asBroadcastStream();
    _subscribeToProgress();
    _extractWaveform();
    _loadSweepSettings();
  }

  Future<void> _loadSweepSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _isSweepEnabled = prefs.getBool('lyrics_sweep_enabled') ?? false;
        });
      }
    } catch (_) {}
  }

  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progressStream != oldWidget.progressStream) {
      _broadcastStream = widget.progressStream.asBroadcastStream();
      _subscribeToProgress();
    }
    // Si cambian las lyrics o el audio, resetear
    if (widget.lyrics != oldWidget.lyrics ||
        widget.audioPath != oldWidget.audioPath) {
      _currentIndexNotifier.value = -1;
      _firstEvent = true;
      _waveformData = [];
      _extractWaveform();
    }
  }

  Future<void> _extractWaveform() async {
    if (widget.audioPath == null) return;

    // Solo extraer si el archivo existe
    try {
      final file = File(widget.audioPath!);
      if (!await file.exists()) return;

      setState(() => _isWaveformLoading = true);

      // Extraemos 1000 muestras para toda la canción
      // Esto nos da una resolución de ~0.2-0.4s por muestra en canciones normales
      final data = await _playerController.extractWaveformData(
        path: widget.audioPath!,
        noOfSamples: 1000,
      );

      if (mounted) {
        setState(() {
          _waveformData = data;
          _isWaveformLoading = false;
        });
      }
    } catch (e) {
      print("[LyricsView] Error extracting waveform: $e");
      if (mounted) setState(() => _isWaveformLoading = false);
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
    _playerController.dispose();
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

              // Last item: Credits
              if (index == _activeLyrics.length + 1) {
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
                    waveformData: _waveformData,
                    songDuration: widget.lyrics?.duration != null
                        ? Duration(seconds: widget.lyrics!.duration!)
                        : null,
                    isSweepEnabled: _isSweepEnabled,
                    tagWords: line.words,
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
  final List<double> waveformData;
  final Duration? songDuration;
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
    this.waveformData = const [],
    this.songDuration,
    this.isSweepEnabled = true,
    this.tagWords,
  });

  /// Calcula el progreso de la línea basado en la energía del audio (waveformData)
  /// Esto permite que el barrido siga fielmente el ritmo real de la canción.
  double _getWaveformProgress(Duration current) {
    if (waveformData.isEmpty ||
        songDuration == null ||
        songDuration!.inMilliseconds == 0)
      return -1.0;

    final startMs = startTime.inMilliseconds;
    final endMs = endTime.inMilliseconds;
    final currentMs = current.inMilliseconds;
    final totalSongMs = songDuration!.inMilliseconds;

    if (currentMs <= startMs) return 0.0;
    if (currentMs >= endMs) return 1.0;

    // Índices en el array de muestras correspondientes al rango de esta línea
    final startIndex = (startMs * waveformData.length / totalSongMs)
        .floor()
        .clamp(0, waveformData.length - 1);
    final endIndex = (endMs * waveformData.length / totalSongMs).floor().clamp(
      0,
      waveformData.length - 1,
    );
    final currentIndex = (currentMs * waveformData.length / totalSongMs)
        .floor()
        .clamp(0, waveformData.length - 1);

    if (startIndex >= endIndex) return -1.0;

    double totalEnergy = 0.0;
    double currentEnergy = 0.0;

    // Calculamos la energía acumulada
    for (int i = startIndex; i <= endIndex; i++) {
      final sample = waveformData[i].abs();
      // Añadimos un pequeño "piso" de energía para que el barrido no se detenga
      // por completo durante silencios absolutos, sino que avance muy lento.
      final energy = sample + 0.05;

      totalEnergy += energy;
      if (i <= currentIndex) {
        currentEnergy += energy;
      }
    }

    if (totalEnergy == 0) return -1.0;
    return (currentEnergy / totalEnergy).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // Estilo base constante para evitar saltos de línea por re-layout
    const baseStyle = TextStyle(
      fontSize: 34, // Tamaño de letra ampliado a petición del usuario
      fontWeight: FontWeight.bold,
      height: 1.3,
      fontFamily: 'Roboto',
    );

    // Dividir texto en palabras para animación granular
    final words = text.split(' ');
    // Usar la longitud completa incluyendo espacios como métrica
    final totalChars = text.length;

    // CÁLCULO DE DURACIÓN DINÁMICO:
    // Evitamos usar el (endTime - startTime) ya que a veces incluye silencios largos y
    // estropea el ritmo visual del barrido. En vez de eso, usamos una aproximación basada
    // en el tiempo de canto promedio
    final charsPerSecond = 12.0; // Velocidad de canto promedio ajustada

    final realDurationMs = (endTime - startTime).inMilliseconds;
    final estimatedDurationMs = ((totalChars / charsPerSecond) * 1000).toInt();

    // Tomamos la menor entre la duración real y la estimada (para no superponernos con la otra)
    int dynamicDurationMs = estimatedDurationMs < realDurationMs
        ? estimatedDurationMs
        : realDurationMs;
    // Garantizamos que el barrido dure al menos algo razonable
    if (dynamicDurationMs < 1000 && realDurationMs > 1000)
      dynamicDurationMs = 1000;
    if (dynamicDurationMs > realDurationMs) dynamicDurationMs = realDurationMs;

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
                child: isSweepEnabled
                    ? _buildActiveKaraoke(
                        baseStyle,
                        dynamicDurationMs,
                        totalChars,
                        words,
                      )
                    : _buildSimpleActiveLine(baseStyle, staticWordWidgets),
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

        // Intentar obtener progreso por Waveform (más preciso)
        double lineProgress = _getWaveformProgress(current);

        if (tagWords != null && tagWords!.isNotEmpty) {
          // Si tenemos timestamps de karaoke reales (ej: de SyncLRC), no aplicamos matemática,
          // renderizamos exactamente según el timing de cada palabra enviada por el proveedor.
          List<Widget> wordWidgets = [];
          for (int i = 0; i < tagWords!.length; i++) {
            final w = tagWords![i];
            final wStart = w.timestamp;
            final wEnd = (i < tagWords!.length - 1)
                ? tagWords![i + 1].timestamp
                : endTime;

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
                word: w.text + (i < tagWords!.length - 1 ? ' ' : ''),
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
        }

        // Si no hay waveform o falló, usar el cálculo por tiempo (fallback)
        if (lineProgress < 0) {
          if (current >= endTime) {
            lineProgress = 1.0;
          } else if (current > startTime) {
            final elapsed = (current - startTime).inMilliseconds;
            if (totalDurationMs > 0) {
              lineProgress = (elapsed / totalDurationMs).clamp(0.0, 1.0);
            }
          } else {
            lineProgress = 0.0;
          }
        }

        // Interpolación fluida
        return TweenAnimationBuilder<double>(
          duration: const Duration(
            milliseconds: 300,
          ), // Aumentamos para suavizar el avance por energía
          curve: Curves.easeOutCubic, // Curva suave para cambios de intensidad
          tween: Tween<double>(begin: lineProgress, end: lineProgress),
          builder: (context, smoothProgress, child) {
            // Determinar "char index" actual global
            final currentCharIndex = smoothProgress * totalChars;

            List<Widget> wordWidgets = [];
            int charAccumulator = 0;

            for (int i = 0; i < words.length; i++) {
              final word = words[i];
              final wordLen = word.length;

              final wordStartChar = charAccumulator;
              final wordEndChar = wordStartChar + wordLen;

              double wordProgress = 0.0;

              // Ajuste de "Overlap" (Suavidad)
              // Hace que el barrido parezca que cruza ligeramente antes y después
              // del límite de la palabra para que la transición entre palabras fluya
              const overlap = 0.5;

              if (currentCharIndex >= wordEndChar + overlap) {
                wordProgress = 1.0;
              } else if (currentCharIndex <= wordStartChar - overlap) {
                wordProgress = 0.0;
              } else {
                final localCurrent =
                    currentCharIndex - (wordStartChar - overlap);
                final localTotal = wordLen + (overlap * 2);
                wordProgress = (localCurrent / localTotal).clamp(0.0, 1.0);
              }

              wordWidgets.add(
                _KaraokeWord(
                  word:
                      word +
                      (i < words.length - 1 ? ' ' : ''), // Usar espacio normal
                  progress: wordProgress,
                  style: textStyle,
                  activeColor: textColor,
                  inactiveColor: textColor.withOpacity(0.3),
                ),
              );

              charAccumulator += wordLen + (i < words.length - 1 ? 1 : 0);
            }

            return Wrap(
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 0.0, // Espacios integrados en las palabras
              runSpacing: 4.0, // Espacio vertical entre líneas si hace wrap
              children: wordWidgets,
            );
          },
        );
      },
    );
  }

  Widget _buildSimpleActiveLine(TextStyle textStyle, List<Widget> _) {
    // Generate simple text with active color
    final wordsArray = text.split(' ');
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
