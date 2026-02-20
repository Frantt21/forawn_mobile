import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/metadata_service.dart';
import '../widgets/artwork_widget.dart';
import 'animated_playing_indicator.dart';
import '../utils/id_generator.dart';
import '../services/local_music_state_service.dart';

/// Widget que carga metadatos de forma lazy (solo cuando es visible)
class LazyMusicTile extends StatefulWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const LazyMusicTile({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<LazyMusicTile> createState() => _LazyMusicTileState();
}

class _LazyMusicTileState extends State<LazyMusicTile> {
  String? _title;
  String? _artist;
  String? _artworkPath;
  String? _artworkUri;
  bool _isLoading = false;
  bool _isLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void didUpdateWidget(LazyMusicTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Check if it's a different song OR if metadata updated (e.g. artwork loaded in background)
    if (oldWidget.song.filePath != widget.song.filePath ||
        oldWidget.song.artworkPath != widget.song.artworkPath ||
        oldWidget.song.title != widget.song.title ||
        oldWidget.song.artist != widget.song.artist) {
      // If we have new data in widget.song, update state immediately
      // This is crucial for when background loading finishes and rebuilds the parent widget
      if (widget.song.artworkPath != null) {
        setState(() {
          _title = widget.song.title;
          _artist = widget.song.artist;
          _artworkPath = widget.song.artworkPath;
          _artworkUri = widget.song.artworkUri;
          _isLoaded = true;
          _isLoading = false;
        });
      } else if (oldWidget.song.filePath != widget.song.filePath) {
        // Only reset and reload if it's a completely different song file
        setState(() {
          _title = null;
          _artist = null;
          _artworkPath = null;
          _artworkUri = null;
          _isLoaded = false;
          _isLoading = false;
        });
        _loadMetadata();
      }
    }
  }

  Future<void> _loadMetadata() async {
    if (_isLoading || _isLoaded) return;

    // Si el Song ya tiene datos completos, usarlos directamente
    if (widget.song.artworkPath != null) {
      if (mounted) {
        setState(() {
          _title = widget.song.title;
          _artist = widget.song.artist;
          _artworkPath = widget.song.artworkPath;
          _artworkUri = widget.song.artworkUri;
          _isLoaded = true;
        });
      }
      return;
    }

    _isLoading = true;

    try {
      final uri = widget.song.filePath;
      final cacheKey = IdGenerator.generateSongId(
        uri,
      ); // Should match MusicLibraryService

      // print('[LazyMusicTile] Loading metadata for ID: $cacheKey, URI: $uri');

      final isSaf = uri.startsWith('content://');

      // Usar MetadataService para cargar con retry y caché automático
      final metadata = await MetadataService().loadMetadata(
        id: cacheKey,
        safUri: isSaf ? uri : null,
        filePath: isSaf ? null : uri,
        priority: MetadataPriority.low, // Baja prioridad para no bloquear
      );

      if (metadata != null) {
        // print('[LazyMusicTile] Metadata loaded for $cacheKey: ${metadata.title}');

        if (mounted) {
          setState(() {
            _title = metadata.title;
            _artist = metadata.artist;
            _artworkPath = metadata.artworkPath;
            _artworkUri = metadata.artworkUri;
            _isLoaded = true;
          });
        }

        // CRITICAL UPDATE: Update the global state so browsing back/forth doesn't re-trigger load
        // Create an updated song object
        final updatedSong = widget.song.copyWith(
          title: metadata.title,
          artist: metadata.artist,
          album: metadata.album,
          duration: metadata.durationMs != null
              ? Duration(milliseconds: metadata.durationMs!)
              : null,
          artworkPath: metadata.artworkPath,
          artworkUri: metadata.artworkUri,
          dominantColor: metadata.dominantColor,
        );

        // Update global state service
        // This ensures the main list has the data for future renders
        LocalMusicStateService().updateSong(uri, updatedSong);
      } else if (mounted) {
        // Si falla, usar datos del Song object
        setState(() {
          _title = widget.song.title;
          _artist = widget.song.artist;
          _isLoaded = true;
        });
      }
    } catch (e) {
      print('[LazyMusicTile] Error loading metadata: $e');
      if (mounted) {
        setState(() {
          _title = widget.song.title;
          _artist = widget.song.artist;
          _isLoaded = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = _title ?? widget.song.title;
    final displayArtist = _artist ?? widget.song.artist;

    Color? activeColor;
    if (widget.isPlaying) {
      final rawColor = widget.song.dominantColor != null
          ? Color(widget.song.dominantColor!)
          : Colors.purpleAccent;
      // Ajuste de brillo igual que en el reproductor
      activeColor = HSLColor.fromColor(rawColor).lightness < 0.3
          ? HSLColor.fromColor(rawColor).withLightness(0.6).toColor()
          : rawColor;
    }

    return ListTile(
      leading: ArtworkWidget(
        artworkPath: _artworkPath,
        artworkUri: _artworkUri,
        size: 48,
        dominantColor: widget.song.dominantColor,
      ),
      title: Text(
        displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: widget.isPlaying ? activeColor : Colors.white,
          fontWeight: widget.isPlaying ? FontWeight.bold : null,
        ),
      ),
      subtitle: Text(
        displayArtist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: widget.isPlaying
          ? SizedBox(
              width: 24,
              height: 24,
              child: AnimatedPlayingIndicator(
                color: activeColor ?? Colors.purpleAccent,
              ),
            )
          : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }
}
