import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

import '../services/music_library_service.dart';
import '../services/music_history_service.dart';
import '../services/audio_player_service.dart';
import '../services/saf_helper.dart';
import '../services/language_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/lazy_music_tile.dart';

import '../services/playlist_service.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import 'playlist_detail_screen.dart';
import 'music_player_screen.dart';

class LocalMusicScreen extends StatefulWidget {
  final String searchQuery;

  const LocalMusicScreen({super.key, this.searchQuery = ''});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  List<Song> _librarySongs = [];
  bool _isLoading = false;
  int _tabIndex = 0; // 0: Library, 1: Playlists
  bool _isGridView = true; // Playlist view mode

  @override
  void initState() {
    super.initState();
    _loadLastFolder();
    PlaylistService().init();
    PlaylistService().addListener(_onPlaylistServiceChanged);
    // Cargar historial y actualizar UI cuando esté listo
    MusicHistoryService().init().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    PlaylistService().removeListener(_onPlaylistServiceChanged);
    super.dispose();
  }

  void _onPlaylistServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLastFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString('last_music_folder');
    if (lastPath != null) {
      _scanFolder(lastPath);
    }
  }

  Future<void> _pickFolder() async {
    final uri = await SafHelper.pickDirectory();
    if (uri != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_music_folder', uri);
      _scanFolder(uri);
    }
  }

  Future<void> _scanFolder(String path) async {
    setState(() => _isLoading = true);
    try {
      final songs = await MusicLibraryService.scanFolder(path);
      if (songs.isNotEmpty) {
        setState(() => _librarySongs = songs);

        if (_audioPlayer.currentSong == null) {
          await _audioPlayer.loadPlaylist(
            songs,
            initialIndex: -1,
            autoPlay: false,
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(LanguageService().getText('no_songs_found'))),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Helper para construir playlist de favoritos
  Playlist _getFavoritesPlaylist() {
    final likedIds = PlaylistService().likedSongIds;
    // Filtrar canciones de la librería que están en favoritos
    final songs = _librarySongs.where((s) => likedIds.contains(s.id)).toList();

    return Playlist(
      id: 'favorites_virtual',
      name: LanguageService().getText('my_favorites'),
      description: LanguageService().getText('favorite_songs_desc'),
      createdAt: DateTime.now(),
      isPinned: true, // Siempre arriba visualmente
      songs: songs,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        StreamBuilder(
          stream: _audioPlayer.playlistStream,
          builder: (context, snapshot) {
            if (_isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            final visibleSongs = _librarySongs;
            final songs = visibleSongs;

            if (songs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.music_note, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(LanguageService().getText('no_songs_loaded')),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _pickFolder,
                      icon: const Icon(Icons.folder),
                      label: Text(LanguageService().getText('select_folder')),
                    ),
                  ],
                ),
              );
            }

            // Normalización para búsqueda
            String normalizeText(String text) {
              return text
                  .toLowerCase()
                  .replaceAll('á', 'a')
                  .replaceAll('é', 'e')
                  .replaceAll('í', 'i')
                  .replaceAll('ó', 'o')
                  .replaceAll('ú', 'u')
                  .replaceAll('ñ', 'n')
                  .replaceAll('ü', 'u');
            }

            final filteredSongs = widget.searchQuery.isEmpty
                ? songs
                : songs.where((song) {
                    final nTitle = normalizeText(song.title);
                    final nArtist = normalizeText(song.artist);
                    final nQuery = normalizeText(widget.searchQuery);
                    return nTitle.contains(nQuery) || nArtist.contains(nQuery);
                  }).toList();

            // Si hay búsqueda activa, mostrar lista simple filtrada
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
                      _buildSongList(
                        songs,
                        showHistory: true,
                        showLibraryHeader: true,
                      ),
                      _buildPlaylistsView(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),

        // Mini Player Positioned
        const Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: SafeArea(child: MiniPlayer()),
        ),
      ],
    );
  }

  Widget _buildCustomTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.transparent,
      child: Row(
        children: [
          _buildTabItem(LanguageService().getText('library'), 0),
          const SizedBox(width: 20),
          _buildTabItem(LanguageService().getText('playlists'), 1),
          const Spacer(),
          if (_tabIndex == 1) ...[
            IconButton(
              icon: Icon(
                Icons.grid_view,
                color: _isGridView ? Colors.white : Colors.white24,
              ),
              onPressed: () => setState(() => _isGridView = true),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: Icon(
                Icons.view_list,
                color: !_isGridView ? Colors.white : Colors.white24,
              ),
              onPressed: () => setState(() => _isGridView = false),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white38,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (isSelected)
            Container(
              margin: const EdgeInsets.only(top: 4),
              height: 3,
              width: 30,
              color: Colors.purpleAccent,
            ),
        ],
      ),
    );
  }

  Widget _buildSongList(
    List<Song> songs, {
    required bool showHistory,
    required bool showLibraryHeader,
  }) {
    final history = MusicHistoryService().history.take(6).toList();
    final hasHistory = showHistory && history.isNotEmpty;

    return CustomScrollView(
      key: PageStorageKey('song_list_${showHistory}_${songs.length}'),
      slivers: [
        // History Section
        if (hasHistory) _buildHistorySectionSliver(),

        // Library Header
        if (showLibraryHeader)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                LanguageService().getText('music_library'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

        // Songs List
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 100),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
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
                      pageBuilder: (context, animation, secondaryAnimation) =>
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
            }, childCount: songs.length),
          ),
        ),
      ],
    );
  }

  Widget _buildHistorySectionSliver() {
    final history = MusicHistoryService().history.take(6).toList();
    if (history.isEmpty)
      return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              LanguageService().getText('recent_history'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.75,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: history.length,
            itemBuilder: (context, index) {
              final song = history[index];
              return GestureDetector(
                onTap: () {
                  _audioPlayer.playSong(song);
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) =>
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
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: song.artworkData != null
                              ? Image.memory(
                                  song.artworkData!,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  color: Colors.grey[800],
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white54,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // --- PLAYLIST VIEW ---

  Widget _buildPlaylistsView() {
    final playlists = PlaylistService().playlists;
    // Combinamos favoritos + playlists
    final itemCount = playlists.length + 1;

    if (_isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.75,
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
          return _buildPlaylistCard(playlists[index - 1]);
        },
      );
    } else {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 100),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildPlaylistTile(
              _getFavoritesPlaylist(),
              isFavorite: true,
            );
          }
          return _buildPlaylistTile(playlists[index - 1]);
        },
      );
    }
  }

  Widget _buildPlaylistCard(Playlist playlist, {bool isFavorite = false}) {
    // Si es Favoritos, mostrar un diseño especial
    final isPinned = playlist.isPinned;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(playlist: playlist),
        ),
      ),
      onLongPress: isFavorite ? null : () => _showPlaylistOptions(playlist),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(12),
                    image: playlist.imagePath != null
                        ? DecorationImage(
                            image:
                                (File(playlist.imagePath!).existsSync()
                                        ? FileImage(File(playlist.imagePath!))
                                        : NetworkImage(playlist.imagePath!))
                                    as ImageProvider,
                            fit: BoxFit.cover,
                          )
                        : null,
                    gradient: isFavorite
                        ? const LinearGradient(
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
                if (isPinned && !isFavorite)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: Icon(Icons.push_pin, color: Colors.white, size: 20),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            playlist.name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            "${playlist.songs.length} canciones",
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistTile(Playlist playlist, {bool isFavorite = false}) {
    return ListTile(
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: isFavorite ? Colors.purple : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
          image: playlist.imagePath != null
              ? DecorationImage(
                  image:
                      (File(playlist.imagePath!).existsSync()
                              ? FileImage(File(playlist.imagePath!))
                              : NetworkImage(playlist.imagePath!))
                          as ImageProvider,
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: playlist.imagePath == null
            ? Icon(
                isFavorite ? Icons.favorite : Icons.music_note,
                color: Colors.white54,
              )
            : null,
      ),
      title: Text(playlist.name, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        "${playlist.songs.length} canciones",
        style: const TextStyle(color: Colors.white54),
      ),
      trailing: (playlist.isPinned && !isFavorite)
          ? const Icon(Icons.push_pin, color: Colors.white54, size: 16)
          : null,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(playlist: playlist),
        ),
      ),
      onLongPress: isFavorite ? null : () => _showPlaylistOptions(playlist),
    );
  }

  // --- OPTIONS & DIALOGS ---

  void _showPlaylistOptions(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              ListTile(
                title: Text(
                  playlist.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                subtitle: Text(
                  "${playlist.songs.length} canciones",
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              const Divider(color: Colors.white24),
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
                  Navigator.pop(ctx);
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
                  Navigator.pop(ctx);
                  _showEditPlaylistDialog(context, playlist);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(
                  LanguageService().getText('delete'),
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeletePlaylist(playlist);
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final isLiked = PlaylistService().isLiked(song.id);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: song.artworkData != null
                      ? Image.memory(
                          song.artworkData!,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          width: 50,
                          height: 50,
                          color: Colors.grey[800],
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white54,
                          ),
                        ),
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const Divider(color: Colors.white24),
              ListTile(
                leading: Icon(
                  isLiked ? Icons.favorite : Icons.favorite_border,
                  color: isLiked ? Colors.red : Colors.white,
                ),
                title: Text(
                  isLiked
                      ? LanguageService().getText('unlike')
                      : LanguageService().getText('like'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  await PlaylistService().toggleLike(song.id);
                  if (mounted) Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add, color: Colors.white),
                title: Text(
                  LanguageService().getText('add_to_playlist'),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            LanguageService().getText('add_to_playlist'),
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.add_circle_outline,
                    color: Colors.purpleAccent,
                  ),
                  title: Text(
                    LanguageService().getText('new_playlist'),
                    style: const TextStyle(color: Colors.purpleAccent),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _showCreatePlaylistDialog(context, songToAdd: song);
                  },
                ),
                ...PlaylistService().playlists.map((playlist) {
                  return ListTile(
                    title: Text(
                      playlist.name,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      "${playlist.songs.length} canciones",
                      style: const TextStyle(color: Colors.white54),
                    ),
                    onTap: () async {
                      await PlaylistService().addSongToPlaylist(
                        playlist.id,
                        song,
                      );
                      if (mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              LanguageService()
                                  .getText('added_to')
                                  .replaceFirst('%s', playlist.name),
                            ),
                            backgroundColor: Colors.purpleAccent,
                          ),
                        );
                      }
                    },
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: Text(
                LanguageService().getText('cancel'),
                style: const TextStyle(color: Colors.white70),
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ],
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
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: Text(
                LanguageService().getText('new_playlist'),
                style: const TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () async {
                      final picker = ImagePicker();
                      final image = await picker.pickImage(
                        source: ImageSource.gallery,
                      );
                      if (image != null) {
                        setState(() => selectedImagePath = image.path);
                      }
                    },
                    child: CircleAvatar(
                      radius: 40,
                      backgroundColor: Colors.grey[800],
                      backgroundImage: selectedImagePath != null
                          ? FileImage(File(selectedImagePath!))
                          : null,
                      child: selectedImagePath == null
                          ? const Icon(Icons.add_a_photo, color: Colors.white54)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: LanguageService().getText('playlist_name'),
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.purpleAccent),
                      ),
                    ),
                  ),
                  TextField(
                    controller: descController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: LanguageService().getText('playlist_desc'),
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.purpleAccent),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(LanguageService().getText('cancel')),
                ),
                TextButton(
                  onPressed: () async {
                    if (nameController.text.isNotEmpty) {
                      final playlist = await PlaylistService().createPlaylist(
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
                    style: const TextStyle(color: Colors.purpleAccent),
                  ),
                ),
              ],
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
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: Text(
                LanguageService().getText('edit_playlist'),
                style: const TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () async {
                      final picker = ImagePicker();
                      final image = await picker.pickImage(
                        source: ImageSource.gallery,
                      );
                      if (image != null) {
                        setState(() => selectedImagePath = image.path);
                      }
                    },
                    child: CircleAvatar(
                      radius: 40,
                      backgroundColor: Colors.grey[800],
                      backgroundImage: selectedImagePath != null
                          ? (File(selectedImagePath!).existsSync()
                                ? FileImage(File(selectedImagePath!))
                                : NetworkImage(selectedImagePath!)
                                      as ImageProvider)
                          : null,
                      child: selectedImagePath == null
                          ? const Icon(Icons.add_a_photo, color: Colors.white54)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: LanguageService().getText('playlist_name'),
                      labelStyle: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextField(
                    controller: descController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: LanguageService().getText('playlist_desc'),
                      labelStyle: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancelar"),
                ),
                TextButton(
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
                  child: const Text(
                    "Guardar",
                    style: TextStyle(color: Colors.purpleAccent),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
