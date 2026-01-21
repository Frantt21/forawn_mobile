import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/audio_player_service.dart';
import '../services/lyrics_service.dart';
import 'lyrics_view.dart';
import 'dart:ui';

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

  @override
  void initState() {
    super.initState();
    _currentSong = widget.song;
    _setupLyricsListener();

    // Escuchar cambios de canción para actualizar el sheet
    _playerSubscription = widget.player.currentSongStream.listen((song) {
      if (song != null && song.id != _currentSong.id) {
        if (mounted) {
          setState(() {
            _currentSong = song;
            _offset = Duration.zero;
            _lyrics = null;
            _isLoading = true;
          });
          // El stream de lyrics se actualizará automáticamente
          // porque AudioPlayerService llama a LyricsService
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
      _isLoading = false;
    } else {
      // Fallback si no se disparó (ej. primera carga app), forzarlo
      LyricsService().setCurrentSong(_currentSong.title, _currentSong.artist);
    }

    // Suscribirse al stream global de lyrics para actualizaciones
    _lyricsSubscription = LyricsService().currentLyricsStream.listen((lyrics) {
      if (mounted) {
        setState(() {
          // Si llega null, es que está cargando NUEVA canción
          if (lyrics == null) {
            _lyrics = null;
            _isLoading = true;
          } else {
            _lyrics = lyrics;
            _isLoading = false;
          }
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

    return Container(
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
                        Container(
                          width: 48,
                          height: 48,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isDark ? Colors.white10 : Colors.black12,
                            image: _currentSong.artworkData != null
                                ? DecorationImage(
                                    image: MemoryImage(
                                      _currentSong.artworkData!,
                                    ),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _currentSong.artworkData == null
                              ? Icon(
                                  Icons.music_note,
                                  color: secondaryTextColor,
                                )
                              : null,
                        ),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Letra',
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
                                    'Sincronizar',
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
                                    'Buscar letra',
                                    style: TextStyle(color: menuTextColor),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
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
                                    'Eliminar letra',
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
                  : LyricsView(
                      lyrics: _lyrics,
                      progressStream: widget.player.progressStream,
                      onSeek: (position) {
                        // Al hacer tap, buscamos ajustando el offset inverso
                        // Si la linea dice 10s y el offset es +1s (tarde), el audio deberia ir a 11s?
                        // No, si offset es retraso visual, el audio es el master.
                        // Simplemente seek al timestamp
                        widget.player.seek(position);
                      },
                      offset: _offset,
                      textColor: textColor,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text(
          'Sincronización',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ajustar tiempo de inicio de letras.\nActual: ${_offset.inMilliseconds}ms',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildSyncButton('-500ms', -500),
                _buildSyncButton('-100ms', -100),
                _buildSyncButton('+100ms', 100),
                _buildSyncButton('+500ms', 500),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Listo'),
          ),
        ],
      ),
    );
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (context) => LyricsSearchDialog(
        initialQuery: '${_currentSong.title} ${_currentSong.artist}',
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

  Widget _buildSyncButton(String label, int ms) {
    return ElevatedButton(
      onPressed: () {
        _adjustOffset(ms);
        Navigator.pop(context);
        _showSyncDialog(); // Reabrir para actualizar texto (hack rápido)
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white10,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(60, 36),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class LyricsSearchDialog extends StatefulWidget {
  final String initialQuery;
  final Function(Lyrics) onLyricSelected;

  const LyricsSearchDialog({
    super.key,
    required this.initialQuery,
    required this.onLyricSelected,
  });

  @override
  State<LyricsSearchDialog> createState() => _LyricsSearchDialogState();
}

class _LyricsSearchDialogState extends State<LyricsSearchDialog> {
  late TextEditingController _controller;
  bool _searching = false;
  List<Lyrics> _results = [];
  String? _error;

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
      final res = await LyricsService().searchLyrics(query);
      if (mounted) {
        setState(() {
          _results = res;
          _searching = false;
          if (res.isEmpty) {
            _error = "No se encontraron resultados";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _error = "Error al buscar";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 500,
            maxHeight: 600,
          ),
          decoration: BoxDecoration(
            color: Colors.grey[900]!.withOpacity(0.95),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(0.1),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  const SizedBox(width: 48),
                  const Expanded(
                    child: Text(
                      'Buscar Letra',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Search Input
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.1),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Título Artista',
                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                    ),
                    border: InputBorder.none,
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
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(
                      color: Colors.purpleAccent,
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
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
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
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
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
        ),
      ),
    );
  }
}
