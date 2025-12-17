// lib/screens/local_music_screen.dart
import 'package:flutter/material.dart';
import 'package:forawn/screens/music_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Para guardar carpeta seleccionada
import '../services/music_library_service.dart';
import '../services/audio_player_service.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';
import '../widgets/mini_player.dart';

class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  // ... (código sin cambios hasta build) ...
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
          const SnackBar(content: Text('No se encontraron canciones mp3')),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Biblioteca Local'),
        actions: [
          // Botón temporal para limpiar caché
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              await MusicMetadataCache.clearOldCache();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Caché de metadata limpiado'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Limpiar Caché',
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFolder,
            tooltip: 'Seleccionar Carpeta',
          ),
        ],
      ),
      body: Column(
        children: [
          // Mini Reproductor
          const MiniPlayer(),

          // Lista de canciones
          Expanded(
            child: StreamBuilder(
              stream: _audioPlayer.playlistStream,
              builder: (context, snapshot) {
                if (_isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                final playlist = snapshot.data;
                final songs = playlist?.songs ?? [];

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
                        const Text('No hay canciones cargadas'),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: _pickFolder,
                          icon: const Icon(Icons.folder),
                          label: const Text('Seleccionar Carpeta'),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
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
                            ? const Icon(
                                Icons.music_note,
                                color: Colors.white54,
                              )
                            : null,
                      ),
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isPlaying
                              ? Theme.of(context).primaryColor
                              : null,
                          fontWeight: isPlaying ? FontWeight.bold : null,
                        ),
                      ),
                      subtitle: Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isPlaying
                          ? const Icon(Icons.graphic_eq, color: Colors.green)
                          : null,
                      onTap: () {
                        // Reproducir esta canción (sin await para no bloquear UI)
                        _audioPlayer.playSong(song);

                        // Abrir pantalla de reproductor inmediatamente
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
          ),
        ],
      ),
    );
  }
}
