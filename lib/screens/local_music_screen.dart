// lib/screens/local_music_screen.dart
import 'package:flutter/material.dart';
import 'package:forawn/screens/music_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/music_library_service.dart';
import '../services/audio_player_service.dart';
import '../services/saf_helper.dart';
import '../services/language_service.dart';
import '../widgets/mini_player.dart';

class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadLastFolder();
  }

  Future<void> _loadLastFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString('last_music_folder');
    if (lastPath != null) {
      _scanFolder(lastPath);
    }
  }

  Future<void> _pickFolder() async {
    // Usar SafHelper para seleccionar carpeta
    final uri = await SafHelper.pickDirectory();
    if (uri != null) {
      // Guardar preferencia
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
        await _audioPlayer.loadPlaylist(songs, initialIndex: -1);
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

  @override
  Widget build(BuildContext context) {
    // Altura base = Status Bar + AppBar para padding
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double appBarHeight = kToolbarHeight;

    return Stack(
      children: [
        // 1. Lista de canciones (Fondo)
        StreamBuilder(
          stream: _audioPlayer.playlistStream,
          builder: (context, snapshot) {
            if (_isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            final playlist = snapshot.data;
            final songs = playlist?.songs ?? [];

            // Padding: Top reducido, Bottom fijo para MiniPlayer (siempre visible)
            final double listTopPadding = 15; //statusBarHeight + appBarHeight -
            final double listBottomPadding = 100; // Siempre visible

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

            return ListView.builder(
              padding: EdgeInsets.only(
                top: listTopPadding,
                bottom: listBottomPadding,
              ),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                final isPlaying = playlist?.currentSong?.id == song.id;

                return ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(4),
                      image: song.artworkData != null
                          ? DecorationImage(
                              image: MemoryImage(song.artworkData!),
                            )
                          : null,
                    ),
                    child: song.artworkData == null
                        ? const Icon(Icons.music_note, color: Colors.white54)
                        : null,
                  ),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isPlaying ? Colors.purpleAccent : Colors.white,
                      fontWeight: isPlaying ? FontWeight.bold : null,
                    ),
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isPlaying
                      ? const Icon(Icons.graphic_eq, color: Colors.purpleAccent)
                      : null,
                  onTap: () {
                    _audioPlayer.playSong(song);
                    if (mounted) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const MusicPlayerScreen(),
                        ),
                      );
                    }
                  },
                );
              },
            );
          },
        ),

        // 2. Mini Reproductor (Flotante - reemplaza al Nav)
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: SafeArea(child: const MiniPlayer()),
        ),
      ],
    );
  }
}
