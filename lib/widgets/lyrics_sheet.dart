import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/audio_player_service.dart';
import '../services/lyrics_service.dart';
import '../services/language_service.dart';
import 'lyrics_view.dart';
import 'dart:ui';
import 'artwork_widget.dart';
import '../models/playback_state.dart';

class LyricsSheet extends StatefulWidget {
  final Song song;
  final AudioPlayerService player;
  final VoidCallback? onTapHeader; // Callback para tap en el header

  const LyricsSheet({
    super.key,
    required this.song,
    required this.player,
    this.onTapHeader,
  });

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  Lyrics? _lyrics;
  Duration _offset = Duration.zero;
  bool _isLoading = true;
  late Song _currentSong;
  StreamSubscription? _lyricsSubscription;
  StreamSubscription? _playerSubscription;
  StreamSubscription? _loadingSubscription; // Nueva suscripción

  @override
  void initState() {
    super.initState();
    _currentSong = widget.song;
    _setupLyricsListener();

    // Escuchar cambios de canción para actualizar el sheet
    _playerSubscription = widget.player.currentSongStream.listen((song) {
      if (song != null) {
        // Actualizar si cambia el ID O si cambian los metadatos clave (título/artista)
        bool metaChanged =
            song.title != _currentSong.title ||
            song.artist != _currentSong.artist ||
            song.artworkPath != _currentSong.artworkPath;

        final oldId = _currentSong.id;

        if (song.id != oldId || metaChanged) {
          if (mounted) {
            setState(() {
              _currentSong = song;
              // Si cambió la canción (ID diferente), resetear offset. Si es solo metadata, mantenerlo.
              if (song.id != oldId) {
                _offset = Duration.zero;
                _lyrics = null;
              } else {
                // Si es la misma canción pero cambió metadata (ej. corrección título),
                // tal vez queramos recargar lyrics con el nuevo título
                if (metaChanged) {
                  _lyrics = null;
                  LyricsService().setCurrentSong(song.title, song.artist);
                }
              }
              // El estado de carga lo manejará el stream de isLoading
            });

            // Fuera del setState, cargar el offset si es una canción nueva
            if (song.id != oldId) {
              _loadSavedOffset();
            }
          }
        }
      }
    });

    _loadSavedOffset();
  }

  void _setupLyricsListener() {
    // Si ya tenemos lyrics cargados en memoria, usarlos inmediatamente para EVITAR loader
    final currentInMemory = LyricsService().currentLyrics;
    if (currentInMemory != null) {
      _lyrics = currentInMemory;
      // isLoading debería venir del servicio, inicializar correctamente
      _isLoading = LyricsService().isLoading;
    } else {
      // Fallback si no se disparó (ej. primera carga app), forzarlo
      LyricsService().setCurrentSong(_currentSong.title, _currentSong.artist);
      _isLoading = true; // Asumir carga inicial
    }

    // Suscribirse al stream global de lyrics para actualizaciones
    _lyricsSubscription = LyricsService().currentLyricsStream.listen((lyrics) {
      if (mounted) {
        setState(() {
          _lyrics = lyrics;
        });
      }
    });

    // Suscribirse al estado de carga
    _loadingSubscription = LyricsService().isLoadingStream.listen((loading) {
      if (mounted) {
        setState(() {
          _isLoading = loading;
        });
      }
    });
  }

  Future<void> _loadSavedOffset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOffsetMs =
          prefs.getInt('lyrics_offset_${_currentSong.id}') ?? 0;
      if (mounted) {
        setState(() {
          _offset = Duration(milliseconds: savedOffsetMs);
        });
      }
    } catch (e) {
      // ignore
    }
  }

  @override
  void dispose() {
    _lyricsSubscription?.cancel();
    _playerSubscription?.cancel();
    _loadingSubscription?.cancel(); // Cancelar nueva suscripción
    super.dispose();
  }

  void _adjustOffset(int milliseconds) async {
    setState(() {
      _offset += Duration(milliseconds: milliseconds);
    });

    // Persistir nuevo offset
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'lyrics_offset_${_currentSong.id}',
      _offset.inMilliseconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _currentSong.dominantColor != null
        ? Color(_currentSong.dominantColor!)
        : const Color(0xFF1C1C1E);

    final brightness = ThemeData.estimateBrightnessForColor(backgroundColor);
    final isDark = brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white70 : Colors.black54;
    final handleColor = isDark
        ? Colors.white.withOpacity(0.3)
        : Colors.black.withOpacity(0.2);
    final iconColor = isDark ? Colors.white : Colors.black87;
    final menuTextColor = isDark ? Colors.white : Colors.black87;
    final menuIconColor = isDark ? Colors.white : Colors.black54;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      // Margin handled by parent
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Header / Handle (Tap zone for expanding)
            GestureDetector(
              onTap: widget.onTapHeader,
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 16, bottom: 24),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: handleColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Toolbar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Row(
                      children: [
                        // Artwork pequeño
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: ArtworkWidget(
                            artworkPath: _currentSong.artworkPath,
                            artworkUri: _currentSong.artworkUri,
                            width: 48,
                            height: 48,
                            borderRadius: BorderRadius.circular(8),
                            dominantColor: _currentSong.dominantColor,
                          ),
                        ),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                LanguageService().getText('lyrics'),
                                style: TextStyle(
                                  color: secondaryTextColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _currentSong.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ).copyWith(color: textColor),
                              ),
                            ],
                          ),
                        ),
                        // Menu Button
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert, color: iconColor),
                          color: isDark
                              ? const Color(0xFF2C2C2E)
                              : Colors.white,
                          onSelected: (value) async {
                            if (value == 'sync') {
                              _showSyncDialog();
                            } else if (value == 'search') {
                              _showSearchDialog();
                            } else if (value == 'delete') {
                              // Limpiar cache local
                              final prefs =
                                  await SharedPreferences.getInstance();
                              final cacheKey =
                                  'lyrics_cache_${'${_currentSong.title.toLowerCase()}_${_currentSong.artist.toLowerCase()}'.replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';
                              await prefs.remove(cacheKey);
                              // Limpiar servicio también
                              LyricsService().clearCurrentLyrics();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'sync',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.timer,
                                    size: 20,
                                    color: menuIconColor,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    LanguageService().getText('sync'),
                                    style: TextStyle(color: menuTextColor),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'search',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search,
                                    size: 20,
                                    color: menuIconColor,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    LanguageService().getText('search_lyrics'),
                                    style: TextStyle(color: menuTextColor),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: Colors.redAccent,
                                  ),
                                  SizedBox(width: 12),
                                  Text(
                                    LanguageService().getText('delete_lyrics'),
                                    style: TextStyle(color: Colors.redAccent),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),

            // Contenido
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: iconColor))
                  : _lyrics == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.lyrics_outlined,
                              size: 48,
                              color: secondaryTextColor.withOpacity(0.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              LanguageService().getText(
                                'lyrics_not_found_manual',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _showSearchDialog,
                              icon: Icon(
                                Icons.search,
                                size: 18,
                                color: textColor,
                              ),
                              label: Text(
                                LanguageService().getText('search_lyrics'),
                                style: TextStyle(color: textColor),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: secondaryTextColor.withOpacity(0.3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : LyricsView(
                      lyrics: _lyrics,
                      progressStream: widget.player.progressStream,
                      onSeek: (position) {
                        widget.player.seek(position);
                      },
                      offset: _offset,
                      textColor: textColor,
                      audioPath: _currentSong.filePath,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  int _getLyricIndex(Duration position) {
    if (_lyrics == null || _lyrics!.syncedLyrics.isEmpty) return -1;
    final lyrics = _lyrics!.syncedLyrics;
    final targetTime = position - _offset;

    for (int i = 0; i < lyrics.length; i++) {
      if (lyrics[i].timestamp > targetTime) {
        return i > 0 ? i - 1 : -1;
      }
    }
    return lyrics.length - 1;
  }

  void _showSyncDialog() {
    Color effectiveColor = _currentSong.dominantColor != null
        ? Color(_currentSong.dominantColor!)
        : Colors.purpleAccent;

    // Asegurar que el color sea legible incluso si el color dominante es muy oscuro
    final hsv = HSVColor.fromColor(effectiveColor);
    if (hsv.value < 0.5) {
      effectiveColor = hsv
          .withValue(0.8)
          .withSaturation((hsv.saturation < 0.3) ? 0.5 : hsv.saturation)
          .toColor();
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        // Usamos StatefulBuilder para actualizar el texto del offset dentro del diálogo
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.5,
              minChildSize: 0.3,
              maxChildSize: 0.8,
              builder: (_, controller) {
                return Container(
                  decoration: BoxDecoration(
                    color:
                        Color.lerp(
                          const Color(0xFF1C1C1E),
                          effectiveColor,
                          0.15,
                        ) ??
                        const Color(0xFF1C1C1E),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 24),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      StreamBuilder<PlaybackProgress>(
                        stream: widget.player.progressStream,
                        builder: (context, snapshot) {
                          final position =
                              snapshot.data?.position ?? Duration.zero;
                          final currentIndex = _getLyricIndex(position);
                          final lyricsList = _lyrics?.syncedLyrics ?? [];

                          final currentText =
                              (currentIndex >= 0 &&
                                  currentIndex < lyricsList.length)
                              ? lyricsList[currentIndex].text
                              : '';
                          final nextText =
                              (currentIndex + 1 < lyricsList.length)
                              ? lyricsList[currentIndex + 1].text
                              : '';

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Header
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: effectiveColor.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.timer,
                                      color: effectiveColor,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          LanguageService().getText(
                                            'synchronization',
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          LanguageService().getText(
                                            'adjust_lyrics_time',
                                          ),
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.6,
                                            ),
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),

                              // Lyrics Preview
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      currentText.isEmpty ? '...' : currentText,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        height: 1.3,
                                      ),
                                    ),
                                    if (nextText.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        nextText,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.5),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),

                              // Current Offset Display
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1E),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '${LanguageService().getText('current')}: ',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.6),
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      '${_offset.inMilliseconds}ms',
                                      style: TextStyle(
                                        color: effectiveColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),

                              // Sync Buttons
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  _buildSyncButton(
                                    '-500ms',
                                    -500,
                                    setDialogState,
                                  ),
                                  _buildSyncButton(
                                    '-100ms',
                                    -100,
                                    setDialogState,
                                  ),
                                  _buildSyncButton(
                                    '+100ms',
                                    100,
                                    setDialogState,
                                  ),
                                  _buildSyncButton(
                                    '+500ms',
                                    500,
                                    setDialogState,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),

                              // Done Button
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () => Navigator.pop(context),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: effectiveColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: Text(
                                    LanguageService().getText('done'),
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showSearchDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => LyricsSearchDialog(
        initialQuery: '${_currentSong.title} ${_currentSong.artist}',
        dominantColor: _currentSong.dominantColor,
        onLyricSelected: (l) async {
          await LyricsService().saveLyricsToCache(
            localTrackName: _currentSong.title,
            localArtistName: _currentSong.artist,
            lyrics: l,
          );
          // Forzar actualización inmediata
          LyricsService().updateLyrics(l);
        },
      ),
    );
  }

  Widget _buildSyncButton(String label, int ms, StateSetter setState) {
    final isNegative = ms < 0;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
          onPressed: () {
            _adjustOffset(ms);
            // Actualizar UI del diálogo
            setState(() {});
            // Actualizar UI del parent (sheet) para visualización inmediata
            // (context as Element).markNeedsBuild(); // Ya no es necesario si _adjustOffset llama a setState del parent, pero el diálogo necesita su propio setState
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: isNegative
                ? Colors.red.withOpacity(0.15)
                : Colors.green.withOpacity(0.15),
            foregroundColor: isNegative ? Colors.redAccent : Colors.greenAccent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class LyricsSearchDialog extends StatefulWidget {
  final String initialQuery;
  final Function(Lyrics) onLyricSelected;
  final int? dominantColor;

  const LyricsSearchDialog({
    super.key,
    required this.initialQuery,
    required this.onLyricSelected,
    this.dominantColor,
  });

  @override
  State<LyricsSearchDialog> createState() => _LyricsSearchDialogState();
}

class _LyricsSearchDialogState extends State<LyricsSearchDialog> {
  late TextEditingController _controller;
  bool _searching = false;
  List<Lyrics> _results = [];
  String? _error;
  String _selectedProvider = 'LRCLIB';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });
    try {
      final res = await LyricsService().searchLyrics(
        query,
        provider: _selectedProvider,
      );
      if (mounted) {
        setState(() {
          _results = res;
          _searching = false;
          if (res.isEmpty) {
            _error = LanguageService().getText('no_results');
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _error = LanguageService().getText('error_searching');
        });
      }
    }
  }

  void _showImportDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF282828),
        title: Text(
          LanguageService().getText('import_lyrics_lrc'),
          style: const TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.9,
          child: TextField(
            controller: textController,
            maxLines: 10,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: LanguageService().getText('paste_lrc_lyrics_here'),
              hintStyle: const TextStyle(color: Colors.white30),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              LanguageService().getText('cancel'),
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () {
              final raw = textController.text.trim();
              if (raw.isNotEmpty) {
                final lines = raw
                    .split('\n')
                    .map((l) => LyricLine.fromString(l))
                    .where((l) => l.text.isNotEmpty)
                    .toList();

                final customLyrics = Lyrics(
                  trackName:
                      widget.initialQuery, // Approximate, overwritten by save
                  artistName: 'Custom',
                  instrumental: false,
                  plainLyrics: lines.map((l) => l.text).join('\n'),
                  syncedLyrics: lines,
                  karaokeLyrics: lines,
                );

                widget.onLyricSelected(customLyrics);
                Navigator.pop(context); // Close import dialog
                Navigator.pop(context); // Close search dialog
              }
            },
            child: Text(
              LanguageService().getText('save'),
              style: const TextStyle(color: Colors.blueAccent),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (_, controller) {
        return Container(
          decoration: BoxDecoration(
            color:
                Color.lerp(
                  const Color(0xFF1C1C1E),
                  widget.dominantColor != null
                      ? Color(widget.dominantColor!)
                      : Colors.purpleAccent,
                  0.15,
                ) ??
                const Color(0xFF1C1C1E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.paste, color: Colors.blueAccent),
                    tooltip: LanguageService().getText(
                      'paste_lrc_lyrics_tooltip',
                    ),
                    onPressed: () => _showImportDialog(context),
                  ),
                  Expanded(
                    child: Text(
                      LanguageService().getText('search_lyrics'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Provider Selector
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _selectedProvider = 'LRCLIB'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _selectedProvider == 'LRCLIB'
                                ? Colors.purpleAccent.withOpacity(0.2)
                                : Colors.transparent,
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(12),
                              right: Radius.circular(
                                _selectedProvider == 'LRCLIB' ? 12 : 0,
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'LRCLIB (Synced)',
                            style: TextStyle(
                              color: _selectedProvider == 'LRCLIB'
                                  ? Colors.purpleAccent
                                  : Colors.white70,
                              fontWeight: _selectedProvider == 'LRCLIB'
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _selectedProvider = 'SyncLRC'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _selectedProvider == 'SyncLRC'
                                ? Colors.purpleAccent.withOpacity(0.2)
                                : Colors.transparent,
                            borderRadius: BorderRadius.horizontal(
                              right: Radius.circular(12),
                              left: Radius.circular(
                                _selectedProvider == 'SyncLRC' ? 12 : 0,
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'SyncLRC (Karaoke)',
                            style: TextStyle(
                              color: _selectedProvider == 'SyncLRC'
                                  ? Colors.purpleAccent
                                  : Colors.white70,
                              fontWeight: _selectedProvider == 'SyncLRC'
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Search Input
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  // border: Border.all(color: Colors.white.withOpacity(0.1)), // Eliminado borde
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white),
                  textAlignVertical:
                      TextAlignVertical.center, // Centrado vertical
                  decoration: InputDecoration(
                    hintText: LanguageService().getText('title_artist'),
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    border: InputBorder.none,
                    isCollapsed: true, // Importante para centrado preciso
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(
                        Icons.search,
                        color: Colors.purpleAccent,
                      ),
                      onPressed: () => _performSearch(_controller.text),
                    ),
                  ),
                  onSubmitted: _performSearch,
                ),
              ),
              const SizedBox(height: 16),

              // Loading
              if (_searching)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: CircularProgressIndicator(
                      color: widget.dominantColor != null
                          ? Color(widget.dominantColor!)
                          : Colors.purpleAccent,
                    ),
                  ),
                ),

              // Error
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),

              // Results List
              if (_results.isNotEmpty)
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final l = _results[index];
                      return InkWell(
                        onTap: () {
                          widget.onLyricSelected(l);
                          Navigator.pop(context);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            // border: Border.all(color: Colors.white.withOpacity(0.05)), // Eliminado borde
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.lyrics_outlined,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.trackName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      l.artistName,
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.5),
                                        fontSize: 13,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              if (l.syncedLyrics.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.timer,
                                    color: Colors.greenAccent,
                                    size: 14,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
