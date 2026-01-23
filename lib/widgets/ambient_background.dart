import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/music_metadata_cache.dart';

class AmbientBackground extends StatefulWidget {
  final List<Song> songs;
  final bool animate;

  const AmbientBackground({
    super.key,
    required this.songs,
    this.animate = true,
  });

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Color> _colors = [Colors.purple, Colors.deepPurple, Colors.black];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // Duración larga para ciclo suave
    )..repeat(); // Ciclo puro (0->1) sin reversa
    _updateColors();
  }

  @override
  void didUpdateWidget(covariant AmbientBackground oldWidget) {
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black, // Fondo base
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Usar senos y cosenos para movimiento fluido y continuo que nunca se detiene
          final t = _controller.value * 2 * math.pi;
          final screenWidth = MediaQuery.of(context).size.width;

          // Radio de órbita horizontal
          final orbitRadius = screenWidth * 0.25;

          return Stack(
            children: [
              // Orbe 1 (Color Base) - Orbita principal
              Positioned(
                top: -100 + (math.sin(t) * 40),
                left: (screenWidth / 2) - 200 + (math.cos(t) * orbitRadius),
                child: _buildOrb(_colors[0], 400 + (math.sin(t) * 30)),
              ),

              // Orbe 2 (Variación Clara) - Contra-órbita (desfase PI)
              Positioned(
                top: -80 + (math.sin(t + math.pi) * 40),
                left:
                    (screenWidth / 2) -
                    180 +
                    (math.cos(t + math.pi) * orbitRadius),
                child: _buildOrb(_colors[1], 360 + (math.cos(t) * 30)),
              ),

              // Orbe 3 (Variación Oscura) - Centro flotante
              if (_colors.length > 2)
                Positioned(
                  top: -140 + (math.sin(t * 0.5) * 30),
                  left: (screenWidth / 2) - 160 + (math.sin(t) * 50),
                  child: _buildOrb(_colors[2].withOpacity(0.4), 320),
                ),

              // Blur para mezclar todo
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
                child: Container(color: Colors.black.withOpacity(0.3)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOrb(Color color, double size) {
    // Usamos AnimatedContainer para cambios suaves si el color o tamaño cambian brscamente por setState
    // Pero el movimiento continuo lo maneja el AnimatedBuilder arriba
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.6),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 100,
            spreadRadius: 20,
          ),
        ],
      ),
    );
  }
}
