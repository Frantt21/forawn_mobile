import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/music_metadata_cache.dart';

/// Versión estática y optimizada del fondo ambiental
/// Sin animaciones para mejor rendimiento
class AmbientBackgroundStatic extends StatefulWidget {
  final List<Song> songs;

  const AmbientBackgroundStatic({super.key, required this.songs});

  @override
  State<AmbientBackgroundStatic> createState() =>
      _AmbientBackgroundStaticState();
}

class _AmbientBackgroundStaticState extends State<AmbientBackgroundStatic> {
  List<Color> _colors = [Colors.purple, Colors.deepPurple, Colors.black];

  @override
  void initState() {
    super.initState();
    _updateColors();
  }

  @override
  void didUpdateWidget(covariant AmbientBackgroundStatic oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.songs != oldWidget.songs) {
      _updateColors();
    }
  }

  Future<void> _updateColors() async {
    Color baseColor = Colors.purple;

    if (widget.songs.isNotEmpty) {
      final firstSong = widget.songs.first;
      // 1. Intentar color de la canción
      if (firstSong.dominantColor != null) {
        baseColor = Color(firstSong.dominantColor!);
      }
      // 2. Intentar buscar en caché
      else {
        final cached = await MusicMetadataCache.get(firstSong.id);
        if (cached?.dominantColor != null) {
          baseColor = Color(cached!.dominantColor!);
        }
      }
    }

    // Generar variaciones armoniosas del mismo color
    final hsl = HSLColor.fromColor(baseColor);

    // Variaciones sutiles para mantener armonía monocromática
    final color1 = baseColor;
    final color2 = hsl
        .withLightness((hsl.lightness + 0.15).clamp(0.0, 1.0))
        .toColor(); // Más brillo
    final color3 = hsl
        .withLightness((hsl.lightness - 0.15).clamp(0.0, 1.0))
        .toColor(); // Más profundidad

    if (mounted) {
      setState(() {
        _colors = [color1, color2, color3];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black, // Fondo base
      child: Stack(
        children: [
          // Gradiente radial que simula el efecto de blur sin BackdropFilter
          // Esto es MUCHO más eficiente
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.0, -0.5),
                radius: 1.2,
                colors: [
                  _colors[0].withOpacity(0.4),
                  _colors[1].withOpacity(0.3),
                  _colors[2].withOpacity(0.2),
                  Colors.black.withOpacity(0.8),
                  Colors.black,
                ],
                stops: const [0.0, 0.3, 0.5, 0.8, 1.0],
              ),
            ),
          ),

          // Capa adicional de gradiente para mayor profundidad
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _colors[0].withOpacity(0.15),
                  Colors.transparent,
                  Colors.black.withOpacity(0.5),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
