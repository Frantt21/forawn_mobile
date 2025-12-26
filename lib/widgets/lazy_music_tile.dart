import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../models/song.dart';
import '../services/saf_helper.dart';
import '../services/music_metadata_cache.dart';
import '../widgets/artwork_container.dart';

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

class _LazyMusicTileState extends State<LazyMusicTile>
    with AutomaticKeepAliveClientMixin {
  String? _title;
  String? _artist;
  Uint8List? _artwork;
  bool _isLoading = false;
  bool _isLoaded = false;

  @override
  bool get wantKeepAlive => true; // Mantener estado al hacer scroll

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void didUpdateWidget(LazyMusicTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.filePath != widget.song.filePath) {
      // Reset state and reload if song changes
      setState(() {
        _title = null;
        _artist = null;
        _artwork = null;
        _isLoaded = false;
        _isLoading = false;
      });
      _loadMetadata();
    }
  }

  Future<void> _loadMetadata() async {
    if (_isLoading || _isLoaded) return;
    _isLoading = true;

    try {
      final uri = widget.song.filePath;
      final cacheKey = uri.hashCode.toString();

      // 1. Intentar desde caché
      final cached = await MusicMetadataCache.get(cacheKey);
      if (cached != null) {
        if (mounted) {
          setState(() {
            // Usar metadatos del caché si existen, sino usar del Song object
            _title = cached.title ?? widget.song.title;
            _artist = cached.artist ?? widget.song.artist;
            _artwork = cached.artwork;
            _isLoaded = true;
          });
        }
        _isLoading = false;
        return;
      }

      // 2. Cargar desde Android (metadatos reales)
      final metadata = await SafHelper.getMetadataFromUri(uri);
      if (metadata != null) {
        final artworkData = metadata['artworkData'] as Uint8List?;
        final realTitle = (metadata['title'] as String?)?.trim();
        final realArtist = (metadata['artist'] as String?)?.trim();

        // Usar metadatos reales si existen, sino usar del Song object (parseo nombre)
        final finalTitle = (realTitle != null && realTitle.isNotEmpty)
            ? realTitle
            : widget.song.title;
        final finalArtist = (realArtist != null && realArtist.isNotEmpty)
            ? realArtist
            : widget.song.artist;

        // Guardar en caché usando metadatos reales
        await MusicMetadataCache.saveFromMetadata(
          key: cacheKey,
          title: finalTitle,
          artist: finalArtist,
          album: metadata['album'] as String?,
          durationMs: metadata['duration'] as int?,
          artworkData: artworkData,
        );

        if (mounted) {
          setState(() {
            _title = finalTitle;
            _artist = finalArtist;
            _artwork = artworkData;
            _isLoaded = true;
          });
        }
      }
    } catch (e) {
      print('[LazyMusicTile] Error loading metadata: $e');
    } finally {
      _isLoading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final displayTitle = _title ?? widget.song.title;
    final displayArtist = _artist ?? widget.song.artist;

    return ListTile(
      leading: ArtworkContainer.song(
        artworkData: _artwork,
        size: 48,
        borderRadius: 4,
      ),
      title: Text(
        displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: widget.isPlaying ? Colors.purpleAccent : Colors.white,
          fontWeight: widget.isPlaying ? FontWeight.bold : null,
        ),
      ),
      subtitle: Text(
        displayArtist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: widget.isPlaying
          ? const Icon(Icons.graphic_eq, color: Colors.purpleAccent)
          : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }
}
