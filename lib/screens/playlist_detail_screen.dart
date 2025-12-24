import 'package:flutter/material.dart';
import 'dart:io'; // Importante para FileImage
import '../models/playlist_model.dart';
import '../models/song.dart';
import '../services/playlist_service.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../widgets/lazy_music_tile.dart';
import 'music_player_screen.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();

  // Estado local para manejar favoritos (que no están en PlaylistService._playlists)
  late List<Song> _virtualSongs;

  @override
  void initState() {
    super.initState();
    _virtualSongs = widget.playlist.songs;
    PlaylistService().addListener(_onPlaylistChanged);
  }

  @override
  void dispose() {
    PlaylistService().removeListener(_onPlaylistChanged);
    super.dispose();
  }

  void _onPlaylistChanged() {
    if (mounted) setState(() {});
  }

  Playlist get _currentPlaylist {
    // Si es favoritos, no está en la lista de BD, usamos la local o widget
    if (widget.playlist.id == 'favorites_virtual') {
      // Si pudiéramos filtrar de nuevo sería ideal, pero no tenemos la librería entera aquí.
      // Así que confiamos en la lista filtrada localmente si borramos algo.
      return widget.playlist.copyWith(songs: _virtualSongs);
    }

    try {
      return PlaylistService().playlists.firstWhere(
        (p) => p.id == widget.playlist.id,
      );
    } catch (e) {
      return widget.playlist;
    }
  }

  void _removeSong(Song song) {
    if (widget.playlist.id == 'favorites_virtual') {
      // Manejo especial para favoritos
      PlaylistService().toggleLike(song.id);
      setState(() {
        _virtualSongs = List.from(_virtualSongs)
          ..removeWhere((s) => s.id == song.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${song.title} ${LanguageService().getText('song_removed_favorites')}",
          ),
        ),
      );
    } else {
      // Playlist normal
      PlaylistService().removeSongFromPlaylist(widget.playlist.id, song.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${song.title} ${LanguageService().getText('song_removed')}",
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;
    final songs = playlist.songs;

    // Si es normal y fue borrada
    if (widget.playlist.id != 'favorites_virtual' &&
        !PlaylistService().playlists.any((p) => p.id == widget.playlist.id)) {
      Navigator.pop(context);
      return Container();
    }

    ImageProvider? headerImage;
    if (playlist.imagePath != null) {
      if (File(playlist.imagePath!).existsSync()) {
        headerImage = FileImage(File(playlist.imagePath!));
      } else {
        headerImage = NetworkImage(playlist.imagePath!); // Fallback si es http
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 250.0,
            floating: false,
            pinned: true,
            backgroundColor: Colors.black,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                playlist.name,
                style: const TextStyle(color: Colors.white),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      image: headerImage != null
                          ? DecorationImage(
                              image: headerImage,
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: headerImage == null
                        ? Icon(
                            widget.playlist.id == 'favorites_virtual'
                                ? Icons.favorite
                                : Icons.music_note,
                            size: 80,
                            color: Colors.white24,
                          )
                        : null,
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(
                  Icons.play_circle_fill,
                  size: 32,
                  color: Colors.purpleAccent,
                ),
                onPressed: () {
                  if (songs.isNotEmpty) {
                    _audioPlayer.loadPlaylist(
                      songs,
                      initialIndex: 0,
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
                  }
                },
              ),
            ],
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  LanguageService().getText('playlist_empty'),
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = songs[index];
                final isPlaying = _audioPlayer.currentSong?.id == song.id;

                return Dismissible(
                  key: Key(
                    "${song.id}_${playlist.id}",
                  ), // Unique key per context
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (direction) => _removeSong(song),
                  child: LazyMusicTile(
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
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.grey[900],
                        builder: (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                title: Text(
                                  LanguageService().getText(
                                    'remove_from_playlist',
                                  ),
                                  style: const TextStyle(color: Colors.red),
                                ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _removeSong(song);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              }, childCount: songs.length),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}
