import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../models/song.dart';
import '../services/metadata_service.dart';
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

      final isSaf = uri.startsWith('content://');

      // Usar MetadataService para cargar con retry y caché automático
      final metadata = await MetadataService().loadMetadata(
        id: cacheKey,
        safUri: isSaf ? uri : null,
        filePath: isSaf ? null : uri,
        priority: MetadataPriority.high, // Alta prioridad porque es visible
      );

      if (metadata != null && mounted) {
        setState(() {
          _title = metadata.title;
          _artist = metadata.artist;
          _artwork = metadata.artwork;
          _isLoaded = true;
        });
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
      // Fallback a datos del Song object
      if (mounted) {
        setState(() {
          _title = widget.song.title;
          _artist = widget.song.artist;
          _isLoaded = true;
        });
      }
    } finally {
      _isLoading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final displayTitle = _title ?? widget.song.title;
    final displayArtist = _artist ?? widget.song.artist;

    return RepaintBoundary(
      child: ListTile(
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
      ),
    );
  }
}
