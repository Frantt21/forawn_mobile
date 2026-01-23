import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import '../services/music_library_service.dart';
import '../services/music_history_service.dart';
import '../services/audio_player_service.dart';
import '../services/saf_helper.dart';
import '../services/language_service.dart';
import '../services/local_music_state_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/lazy_music_tile.dart';

import '../widgets/song_options_bottom_sheet.dart';
import '../services/music_metadata_cache.dart';
import '../widgets/assistant_chat_dialog.dart';

import '../services/playlist_service.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import '../utils/text_utils.dart';
import 'playlist_detail_screen.dart';
import 'music_player_screen.dart';
import '../widgets/local_music_home.dart';
import '../widgets/ambient_background.dart';

class LocalMusicScreen extends StatefulWidget {
  final String searchQuery;

  const LocalMusicScreen({super.key, this.searchQuery = ''});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final LocalMusicStateService _musicState = LocalMusicStateService();
  int _tabIndex = 0; // 0: Library, 1: Playlists
  bool _isGridView = true; // Playlist view mode

  // Búsqueda
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Estado de carga de metadatos
  String? _loadingMessage;
  double? _loadingProgress;
  StreamSubscription? _progressSubscription;
  StreamSubscription? _songSubscription;

  @override
  bool get wantKeepAlive => true; // Mantener estado activo

  @override
  void initState() {
    super.initState();
    // Inicializar servicio de música local (solo carga si no se ha hecho antes)
    _musicState.init();
    _musicState.addListener(_onMusicStateChanged);

    PlaylistService().init();
    PlaylistService().addListener(_onPlaylistServiceChanged);
    MusicLibraryService.onMetadataUpdated.addListener(
      _onMetadataUpdated,
    ); // Escuchar actualizaciones de artwork
    // Cargar historial y actualizar UI cuando esté listo
    MusicHistoryService().init().then((_) {
      if (mounted) setState(() {});
    });

    // Escuchar progreso de metadatos - DESACTIVADO (no necesario)
    /* _progressSubscription = MetadataService().progressStream.listen((data) {
      if (mounted) {
        setState(() {
          _loadingMessage = data['message'];
          _loadingProgress = data['progress'];
        });

        // Si el progreso está completo (1.0), ocultar el mensaje después de 1 segundo
        if (data['progress'] == 1.0) {
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) {
              setState(() {
                _loadingMessage = null;
                _loadingProgress = null;
              });
            }
          });
        }
      }
    }); */

    // Escuchar servicio de historial directamente
    // Escuchar servicio de historial directamente
    MusicHistoryService().addListener(_onHistoryChanged);
    // Iniciar carga de historial
    MusicHistoryService().init();

    // Inicializar animación de búsqueda
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _searchController.dispose();
    _musicState.removeListener(_onMusicStateChanged);
    PlaylistService().removeListener(_onPlaylistServiceChanged);
    MusicLibraryService.onMetadataUpdated.removeListener(_onMetadataUpdated);
    _progressSubscription?.cancel();
    _songSubscription?.cancel();
    // Clear loading message on dispose
    _loadingMessage = null;
    _loadingProgress = null;
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  void _onMusicStateChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaylistServiceChanged() {
    if (mounted) setState(() {});
  }

  // Cuando llega metadata nueva en background (ej. artwork), actualizar la canción en el servicio
  void _onMetadataUpdated() async {
    final uri = MusicLibraryService.onMetadataUpdated.value;
    if (uri != null && mounted) {
      final songs = _musicState.librarySongs;
      final index = songs.indexWhere((s) => s.filePath == uri);
      if (index != -1) {
        // Encontrada! Recargar sus datos del caché
        final cacheKey = uri.hashCode.toString();
        final cached = await MusicMetadataCache.get(cacheKey);

        if (cached != null) {
          final updatedSong = songs[index].copyWith(
            title: cached.title ?? songs[index].title,
            artist: cached.artist ?? songs[index].artist,
            album: cached.album,
            duration: cached.durationMs != null
                ? Duration(milliseconds: cached.durationMs!)
                : null,
            artworkData: cached.artwork, // Aquí llega el artwork
          );
          _musicState.updateSong(uri, updatedSong);
        }
      }
    }
  }

  Future<void> _pickFolder() async {
    final uri = await SafHelper.pickDirectory();
    if (uri != null) {
      // Mostrar diálogo de progreso
      if (!mounted) return;

      // Variable para controlar si el diálogo está abierto
      bool dialogOpen = true;

      showDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withOpacity(0.5),
        builder: (context) => _buildLoadingDialog(),
      ).then((_) => dialogOpen = false); // Detectar cierre

      try {
        // Pequeña pausa para que el diálogo se renderice
        await Future.delayed(const Duration(milliseconds: 100));

        await _musicState.loadFolder(uri, forceReload: true);

        // Cargar playlist en el reproductor si está vacío
        final songs = _musicState.librarySongs;
        if (songs.isNotEmpty && _audioPlayer.currentSong == null) {
          await _audioPlayer.loadPlaylist(
            songs,
            initialIndex: -1,
            autoPlay: false,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      } finally {
        // Cerrar diálogo si sigue abierto
        if (dialogOpen && mounted) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  Widget _buildLoadingDialog() {
    return ValueListenableBuilder<LibraryLoadingStatus>(
      valueListenable: MusicLibraryService.loadingStatus,
      builder: (context, status, child) {
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey[900]!.withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Cargando librería',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Circular Progress con porcentaje
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 80,
                        height: 80,
                        child: CircularProgressIndicator(
                          value: status.progress > 0 ? status.progress : null,
                          strokeWidth: 6,
                          backgroundColor: Colors.white10,
                          color: Colors.purpleAccent,
                        ),
                      ),
                      Text(
                        '${(status.progress * 100).toInt()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  Text(
                    status.message.isEmpty ? 'Preparando...' : status.message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Helper para construir playlist de favoritos
  Playlist _getFavoritesPlaylist() {
    final likedIds = PlaylistService().likedSongIds;
    // Crear mapa para búsqueda rápida
    final librarySongsMap = {for (var s in _musicState.librarySongs) s.id: s};

    // Mapear manteniendo el orden de likedIds (que es cronológico de inserción)
    final songs = likedIds
        .map((id) => librarySongsMap[id])
        .whereType<Song>()
        .toList();

    return Playlist(
      id: 'favorites_virtual',
      name: LanguageService().getText('my_favorites'),
      description: LanguageService().getText('favorite_songs_desc'),
      createdAt: DateTime.now(),
      isPinned: true, // Siempre arriba visualmente
      songs: songs,
    );
  }

  // Filtrar canciones basado en la búsqueda
  List<Song> _getFilteredSongs(List<Song> songs) {
    if (_searchQuery.isEmpty) {
      return songs;
    }

    final query = _searchQuery.toLowerCase();
    return songs.where((song) {
      return song.title.toLowerCase().contains(query) ||
          (song.artist.toLowerCase().contains(query)) ||
          (song.album?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  // Campo de búsqueda animado
  Widget _buildSearchField() {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return FadeTransition(
          opacity: _fadeAnimation,
          child: TextField(
            controller: _searchController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
            decoration: InputDecoration(
              hintText: 'Buscar canciones...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
              border: InputBorder.none,
            ),
          ),
        );
      },
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    super.build(context); // Actualizar estado de KeepAlive

    return StreamBuilder<Song?>(
      stream: _audioPlayer.currentSongStream,
      builder: (context, songSnapshot) {
        final currentSong = songSnapshot.data;
        // final dominantColor = currentSong?.dominantColor != null
        //     ? Color(currentSong!.dominantColor!)
        //     : null;

        return ListenableBuilder(
          listenable: LanguageService(),
          builder: (context, _) {
            return Scaffold(
              backgroundColor: const Color.fromARGB(255, 34, 34, 34),
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                title: _isSearching
                    ? _buildSearchField()
                    : const Text('Local Music'),
                backgroundColor: Colors.transparent,
                elevation: 0,
                actions: [
                  // Search button
                  IconButton(
                    icon: Icon(_isSearching ? Icons.close : Icons.search),
                    onPressed: () {
                      setState(() {
                        _isSearching = !_isSearching;
                        if (_isSearching) {
                          _animationController.forward();
                        } else {
                          _animationController.reverse();
                          _searchController.clear();
                          _searchQuery = '';
                        }
                      });
                    },
                    tooltip: _isSearching ? 'Cerrar búsqueda' : 'Buscar',
                  ),
                  // AI Assistant button
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      // decoration: BoxDecoration(
                      //   gradient: LinearGradient(
                      //     colors: [
                      //       Theme.of(context).primaryColor,
                      //       Theme.of(context).primaryColor.withOpacity(0.7),
                      //     ],
                      //   ),
                      //   borderRadius: BorderRadius.circular(8),
                      // ),
                      child: const Icon(
                        Icons.smart_toy_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    tooltip: 'Asistente Musical',
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => const AssistantChatDialog(),
                      );
                    },
                  ),
                  // Folder picker button
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickFolder,
                    tooltip: 'Seleccionar Carpeta',
                  ),
                ],
              ),
              body: Stack(
                children: [
                  // 1. Ambient Background Layer (History Based)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: (_tabIndex == 0 && !_isSearching) ? 1.0 : 0.0,
                      child: AmbientBackground(
                        songs: MusicHistoryService().history,
                      ),
                    ),
                  ),

                  // 2. Main Content Layer
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.only(
                        top:
                            MediaQuery.of(context).padding.top + kToolbarHeight,
                      ),
                      child: StreamBuilder(
                        stream: _audioPlayer.playlistStream,
                        builder: (context, snapshot) {
                          if (_musicState.isLoading) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final visibleSongs = _musicState.librarySongs;
                          final songs = _getFilteredSongs(visibleSongs);

                          if (songs.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.music_note,
                                    size: 64,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    LanguageService().getText(
                                      'no_songs_loaded',
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed: _pickFolder,
                                    icon: const Icon(Icons.folder),
                                    label: Text(
                                      LanguageService().getText(
                                        'select_folder',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          final filteredSongs = widget.searchQuery.isEmpty
                              ? songs
                              : songs.where((song) {
                                  final nTitle = TextUtils.normalize(
                                    song.title,
                                  );
                                  final nArtist = TextUtils.normalize(
                                    song.artist,
                                  );
                                  final nQuery = TextUtils.normalize(
                                    widget.searchQuery,
                                  );
                                  return nTitle.contains(nQuery) ||
                                      nArtist.contains(nQuery);
                                }).toList();

                          // Si hay búsqueda activa
                          if (widget.searchQuery.isNotEmpty) {
                            return _buildSongList(
                              filteredSongs,
                              showHistory: false,
                              showLibraryHeader: false,
                            );
                          }

                          // Si no, mostrar Tabs
                          return Column(
                            children: [
                              _buildCustomTabBar(),
                              Expanded(
                                child: IndexedStack(
                                  index: _tabIndex,
                                  children: [
                                    // Index 0: Home
                                    LocalMusicHome(
                                      favoriteSongs:
                                          _getFavoritesPlaylist().songs,
                                      onSongTap: (song) {
                                        final history =
                                            MusicHistoryService().history;
                                        final playlist = Playlist(
                                          id: 'history_playback',
                                          name: LanguageService().getText(
                                            'recently_played',
                                          ),
                                          createdAt: DateTime.now(),
                                          songs: history,
                                        );
                                        _audioPlayer.loadPlaylist(
                                          playlist.songs,
                                          initialIndex: history.indexWhere(
                                            (s) => s.id == song.id,
                                          ),
                                        );
                                      },
                                      onCreatePlaylist: () =>
                                          _showCreatePlaylistDialog(context),
                                      onPlaylistTap: (playlist) {
                                        PlaylistService().logPlaylistOpen(
                                          playlist.id,
                                        );
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                PlaylistDetailScreen(
                                                  playlist: playlist,
                                                ),
                                          ),
                                        );
                                      },
                                    ),
                                    // Index 1: Library
                                    _buildSongList(
                                      songs,
                                      showHistory: false,
                                      showLibraryHeader: true,
                                    ),
                                    // Index 2: Playlists
                                    _buildPlaylistsView(),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),

                  // 3. Loading Indicator
                  if (_loadingMessage != null && _loadingMessage!.isNotEmpty)
                    Positioned(
                      bottom: 80,
                      left: 16,
                      right: 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.8),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.1),
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    value: _loadingProgress,
                                    strokeWidth: 2,
                                    color: Theme.of(context).primaryColor,
                                    backgroundColor: Colors.white10,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _loadingMessage!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // 4. Mini Player
                  const Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: SafeArea(child: MiniPlayer()),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCustomTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      height: 56, // Altura fija para evitar desplazamientos
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.center, // Alineación vertical fija
        children: [
          // Sección de Pestañas (Scrollable y Expandida)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTabItem(LanguageService().getText('home'), 0),
                  const SizedBox(width: 8),
                  _buildTabItem(LanguageService().getText('library'), 1),
                  const SizedBox(width: 8),
                  _buildTabItem(LanguageService().getText('playlists'), 2),
                ],
              ),
            ),
          ),

          // Sección de Botones de Acción (Fija a la derecha)
          if (_tabIndex == 2) ...[
            const SizedBox(width: 16),
            // Grid view button - estilo pastilla
            GestureDetector(
              onTap: () => setState(() => _isGridView = true),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _isGridView
                      ? Colors.white.withOpacity(0.2) // Activo
                      : Colors.white.withOpacity(0.05), // Inactivo
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.grid_view,
                  color: _isGridView ? Colors.white : Colors.white60,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // List view button - estilo pastilla
            GestureDetector(
              onTap: () => setState(() => _isGridView = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: !_isGridView
                      ? Colors.white.withOpacity(0.2) // Activo
                      : Colors.white.withOpacity(0.05), // Inactivo
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.view_list,
                  color: !_isGridView ? Colors.white : Colors.white60,
                  size: 20,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTabItem(String title, int index) {
    final isSelected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withOpacity(0.2) // Más claro cuando está activo
              : Colors.white.withOpacity(
                  0.05,
                ), // Más oscuro cuando no está activo
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            height: 1.0, // Altura de línea fija para consistencia
          ),
        ),
      ),
    );
  }

  Widget _buildSongList(
    List<Song> songs, {
    required bool showHistory,
    required bool showLibraryHeader,
  }) {
    // final history = MusicHistoryService().history.take(6).toList();
    // final hasHistory = showHistory && history.isNotEmpty;

    return RefreshIndicator(
      onRefresh: () async {
        // Usar el método refresh del servicio para recargar
        await _musicState.refresh();

        // Actualizar playlist del reproductor si es necesario
        final songs = _musicState.librarySongs;
        if (songs.isNotEmpty && _audioPlayer.currentSong == null) {
          await _audioPlayer.loadPlaylist(
            songs,
            initialIndex: -1,
            autoPlay: false,
          );
        }
      },
      child: CustomScrollView(
        key: PageStorageKey('song_list_${showHistory}_${songs.length}'),
        slivers: [
          // History Section - Not used in Library view
          // if (hasHistory)

          // Library Header
          if (showLibraryHeader)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  LanguageService().getText('music_library'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Songs List
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 100),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index < 0 || index >= songs.length) {
                    return const SizedBox.shrink();
                  }

                  final song = songs[index];
                  final isPlaying = _audioPlayer.currentSong?.id == song.id;

                  return LazyMusicTile(
                    key: ValueKey(song.id),
                    song: song,
                    isPlaying: isPlaying,
                    onTap: () {
                      _audioPlayer.loadPlaylist(
                        songs,
                        initialIndex: index,
                        autoPlay: true,
                      );
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const MusicPlayerScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                var tween = Tween(
                                  begin: const Offset(0.0, 1.0),
                                  end: Offset.zero,
                                ).chain(CurveTween(curve: Curves.easeOutCubic));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                    onLongPress: () => _showSongOptions(context, song),
                  );
                },
                childCount: songs.length,
                addRepaintBoundaries:
                    true, // ✅ OPTIMIZACIÓN: Repaint boundaries automáticos
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- PLAYLIST VIEW ---

  Widget _buildPlaylistsView() {
    final playlists = PlaylistService().playlists;
    // Combinamos favoritos + playlists + botón crear
    final itemCount = playlists.length + 2;

    if (_isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.0,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildPlaylistCard(
              _getFavoritesPlaylist(),
              isFavorite: true,
            );
          }
          // Last item: Create Playlist Button
          if (index == itemCount - 1) {
            return _buildCreatePlaylistCard();
          }
          return _buildPlaylistCard(playlists[index - 1]);
        },
      );
    } else {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 100),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildPlaylistTile(
              _getFavoritesPlaylist(),
              isFavorite: true,
            );
          }
          // Last item: Create Playlist Tile
          if (index == itemCount - 1) {
            return _buildCreatePlaylistTile();
          }
          return _buildPlaylistTile(playlists[index - 1]);
        },
      );
    }
  }

  Widget _buildCreatePlaylistCard() {
    return GestureDetector(
      onTap: () => _showCreatePlaylistDialog(context),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900], // Fondo oscuro sutil
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
            width: 1,
            style: BorderStyle.solid,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.purpleAccent.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.add,
                color: Colors.purpleAccent,
                size: 30,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              LanguageService().getText('create_playlist'),
              style: const TextStyle(
                color: Colors.purpleAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreatePlaylistTile() {
    return ListTile(
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: Colors.purpleAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.add, color: Colors.purpleAccent),
      ),
      title: Text(
        LanguageService().getText('create_playlist'),
        style: const TextStyle(
          color: Colors.purpleAccent,
          fontWeight: FontWeight.bold,
        ),
      ),
      onTap: () => _showCreatePlaylistDialog(context),
    );
  }

  Widget _buildPlaylistTile(Playlist playlist, {bool isFavorite = false}) {
    return ListTile(
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(8),
          image: playlist.getImageProvider() != null
              ? DecorationImage(
                  image: playlist.getImageProvider()!,
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: playlist.getImageProvider() == null
            ? Icon(
                isFavorite ? Icons.favorite : Icons.music_note,
                color: isFavorite ? Colors.purpleAccent : Colors.white54,
              )
            : null,
      ),
      title: Text(
        playlist.name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '${playlist.songs.length} ${LanguageService().getText('songs')}',
        style: TextStyle(color: Colors.white.withOpacity(0.6)),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(playlist: playlist),
        ),
      ),
      onLongPress: isFavorite ? null : () => _showPlaylistOptions(playlist),
    );
  }

  Widget _buildPlaylistCard(Playlist playlist, {bool isFavorite = false}) {
    final isPinned = playlist.isPinned;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(playlist: playlist),
        ),
      ),
      onLongPress: isFavorite ? null : () => _showPlaylistOptions(playlist),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Background (Image or Gradient)
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  image: playlist.getImageProvider() != null
                      ? DecorationImage(
                          image: playlist.getImageProvider()!,
                          fit: BoxFit.cover,
                        )
                      : null,
                  gradient: isFavorite
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.purple, Colors.deepPurple],
                        )
                      : null,
                ),
                child: playlist.imagePath == null
                    ? Center(
                        child: Icon(
                          isFavorite ? Icons.favorite : Icons.music_note,
                          color: Colors.white24,
                          size: 48,
                        ),
                      )
                    : null,
              ),

              // 2. Gradient Overlay for Text Readability
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.2),
                      Colors.black.withOpacity(0.8),
                    ],
                    stops: const [0.5, 0.7, 1.0],
                  ),
                ),
              ),

              // 3. Pinned Icon (Top Right)
              if (isPinned && !isFavorite)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.push_pin,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),

              // 4. Text Content (Bottom Left)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${playlist.songs.length} ${LanguageService().getText('songs')}",
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 12,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- OPTIONS & DIALOGS ---

  void _showPlaylistOptions(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.only(top: 16),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Header Info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        image: playlist.imagePath != null
                            ? DecorationImage(
                                image: File(playlist.imagePath!).existsSync()
                                    ? FileImage(File(playlist.imagePath!))
                                    : NetworkImage(playlist.imagePath!)
                                          as ImageProvider,
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: playlist.imagePath == null
                          ? const Icon(Icons.music_note, color: Colors.white54)
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playlist.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          Text(
                            "${playlist.songs.length} ${LanguageService().getText('songs')}",
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Divider(color: Colors.white10),
              ),

              // Options
              ListTile(
                leading: Icon(
                  playlist.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                  color: playlist.isPinned ? Colors.white54 : Colors.white,
                ),
                title: Text(
                  playlist.isPinned
                      ? LanguageService().getText('unpin')
                      : LanguageService().getText('pin'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  PlaylistService().togglePin(playlist.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white),
                title: Text(
                  LanguageService().getText('edit'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showEditPlaylistDialog(context, playlist);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.redAccent),
                title: Text(
                  LanguageService().getText('delete'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeletePlaylist(playlist);
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeletePlaylist(Playlist playlist) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          LanguageService().getText('delete_playlist'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          LanguageService()
              .getText('delete_playlist_confirm')
              .replaceFirst('%s', playlist.name),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () {
              PlaylistService().deletePlaylist(playlist.id);
              Navigator.pop(ctx);
            },
            child: const Text("Eliminar", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showSongOptions(BuildContext context, Song song) {
    SongOptionsBottomSheet.show(
      context: context,
      song: song,
      options: [SongOption.like, SongOption.addToPlaylist, SongOption.delete],
      onAddToPlaylist: () => _showAddToPlaylistDialog(context, song),
      onOptionSelected: (option) {
        if (option == SongOption.delete) {
          _confirmDeleteSong(context, song);
        }
      },
    );
  }

  void _confirmDeleteSong(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          LanguageService().getText('delete'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          LanguageService()
              .getText('delete_song_confirm')
              .replaceFirst('%s', song.title),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(LanguageService().getText('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx); // Cerrar dialogo
              try {
                final success = await SafHelper.deleteFile(song.filePath);
                if (success) {
                  // Actualizar librería
                  await _musicState.refresh();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          LanguageService().getText('song_deleted'),
                        ),
                      ),
                    );
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          LanguageService().getText('delete_file_error'),
                        ),
                      ),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            child: Text(
              LanguageService().getText('delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (context) {
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 500),
              decoration: BoxDecoration(
                color: Colors.grey[900]!.withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Título
                    Text(
                      LanguageService().getText('add_to_playlist'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Botón de nueva playlist
                    InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        _showCreatePlaylistDialog(context, songToAdd: song);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.purpleAccent.withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.purpleAccent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.add_circle_outline,
                                color: Colors.purpleAccent,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              LanguageService().getText('new_playlist'),
                              style: const TextStyle(
                                color: Colors.purpleAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Lista de playlists
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: PlaylistService().playlists.map((playlist) {
                            // Verificar si la canción ya está en la playlist
                            final songExists = playlist.songs.any(
                              (s) => s.id == song.id,
                            );

                            return InkWell(
                              onTap: songExists
                                  ? null
                                  : () async {
                                      await PlaylistService().addSongToPlaylist(
                                        playlist.id,
                                        song,
                                      );
                                      if (mounted) {
                                        Navigator.pop(context);
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              LanguageService()
                                                  .getText('added_to')
                                                  .replaceFirst(
                                                    '%s',
                                                    playlist.name,
                                                  ),
                                            ),
                                            backgroundColor:
                                                Colors.purpleAccent,
                                          ),
                                        );
                                      }
                                    },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: songExists
                                      ? Colors.white.withOpacity(0.03)
                                      : Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    // Imagen de la playlist
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1C1C1E),
                                        borderRadius: BorderRadius.circular(8),
                                        image: playlist.imagePath != null
                                            ? DecorationImage(
                                                image:
                                                    File(
                                                      playlist.imagePath!,
                                                    ).existsSync()
                                                    ? FileImage(
                                                        File(
                                                          playlist.imagePath!,
                                                        ),
                                                      )
                                                    : NetworkImage(
                                                            playlist.imagePath!,
                                                          )
                                                          as ImageProvider,
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: playlist.imagePath == null
                                          ? const Icon(
                                              Icons.music_note,
                                              color: Colors.white54,
                                              size: 24,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 16),
                                    // Info de la playlist
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            playlist.name,
                                            style: TextStyle(
                                              color: songExists
                                                  ? Colors.white54
                                                  : Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "${playlist.songs.length} ${LanguageService().getText('songs')}",
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.5,
                                              ),
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Indicador si ya existe
                                    if (songExists)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.check_circle,
                                              color: Colors.green,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              LanguageService().getText(
                                                'added',
                                              ),
                                              style: const TextStyle(
                                                color: Colors.green,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Botón cerrar
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          LanguageService().getText('cancel'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCreatePlaylistDialog(
    BuildContext context, {
    Song? songToAdd,
  }) async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    String? selectedImagePath;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  decoration: BoxDecoration(
                    color: Colors.grey[900]!.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Título
                          Text(
                            LanguageService().getText('new_playlist'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Imagen cuadrada
                          Center(
                            child: GestureDetector(
                              onTap: () async {
                                final picker = ImagePicker();
                                final image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                );
                                if (image != null) {
                                  setState(
                                    () => selectedImagePath = image.path,
                                  );
                                }
                              },
                              child: Container(
                                width: 180,
                                height: 180,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1E),
                                  borderRadius: BorderRadius.circular(16),
                                  image: selectedImagePath != null
                                      ? DecorationImage(
                                          image: FileImage(
                                            File(selectedImagePath!),
                                          ),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: selectedImagePath == null
                                    ? const Icon(
                                        Icons.add_photo_alternate,
                                        color: Colors.white54,
                                        size: 56,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Input de nombre estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_name'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: nameController,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_name',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Input de descripción estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_desc'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: descController,
                                    maxLines: 3,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_desc',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Botones
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(
                                  LanguageService().getText('cancel'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purpleAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  if (nameController.text.isNotEmpty) {
                                    final playlist = await PlaylistService()
                                        .createPlaylist(
                                          nameController.text,
                                          description: descController.text,
                                          imagePath: selectedImagePath,
                                        );
                                    if (songToAdd != null) {
                                      await PlaylistService().addSongToPlaylist(
                                        playlist.id,
                                        songToAdd,
                                      );
                                    }
                                    if (mounted) Navigator.pop(ctx);
                                  }
                                },
                                child: Text(
                                  LanguageService().getText('create'),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showEditPlaylistDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    String? selectedImagePath = playlist.imagePath;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  decoration: BoxDecoration(
                    color: Colors.grey[900]!.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Título
                          Text(
                            LanguageService().getText('edit_playlist'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Imagen cuadrada
                          Center(
                            child: GestureDetector(
                              onTap: () async {
                                final picker = ImagePicker();
                                final image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                );
                                if (image != null) {
                                  setState(
                                    () => selectedImagePath = image.path,
                                  );
                                }
                              },
                              child: Container(
                                width: 180,
                                height: 180,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1E),
                                  borderRadius: BorderRadius.circular(16),
                                  image: selectedImagePath != null
                                      ? DecorationImage(
                                          image:
                                              File(
                                                selectedImagePath!,
                                              ).existsSync()
                                              ? FileImage(
                                                  File(selectedImagePath!),
                                                )
                                              : NetworkImage(selectedImagePath!)
                                                    as ImageProvider,
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: selectedImagePath == null
                                    ? const Icon(
                                        Icons.add_photo_alternate,
                                        color: Colors.white54,
                                        size: 56,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Input de nombre estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_name'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: nameController,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_name',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Input de descripción estilo Card
                          Card(
                            color: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LanguageService().getText('playlist_desc'),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: descController,
                                    maxLines: 3,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                    cursorColor: Colors.purpleAccent,
                                    decoration: InputDecoration(
                                      hintText: LanguageService().getText(
                                        'playlist_desc',
                                      ),
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Botones
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(
                                  LanguageService().getText('cancel'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purpleAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  if (nameController.text.isNotEmpty) {
                                    await PlaylistService().updatePlaylist(
                                      playlist.id,
                                      name: nameController.text,
                                      description: descController.text,
                                      imagePath: selectedImagePath,
                                    );
                                    if (mounted) Navigator.pop(ctx);
                                  }
                                },
                                child: Text(
                                  LanguageService().getText('save'),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
