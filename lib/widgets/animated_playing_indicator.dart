import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/audio_player_service.dart';
import '../models/playback_state.dart' as app_state;

class AnimatedPlayingIndicator extends StatefulWidget {
  final Color color;
  const AnimatedPlayingIndicator({super.key, required this.color});

  @override
  State<AnimatedPlayingIndicator> createState() =>
      _AnimatedPlayingIndicatorState();
}

class _AnimatedPlayingIndicatorState extends State<AnimatedPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<app_state.PlayerState>(
      stream: AudioPlayerService().playerStateStream,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data == app_state.PlayerState.playing;

        if (!isPlaying) {
          _controller.stop();
        } else if (!_controller.isAnimating) {
          _controller.repeat();
        }

        return Container(
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildBar(0, isPlaying),
                  _buildBar(1, isPlaying),
                  _buildBar(2, isPlaying),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBar(int index, bool isPlaying) {
    if (!isPlaying) {
      return Container(
        width: 4,
        height: 8 + (index * 4).toDouble(), // Escalera estática
        decoration: BoxDecoration(
          color: widget.color.withOpacity(0.5), // Use widget color but dimmed
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Generar una onda simple basada en seno
        final t = _controller.value;
        final offset = index * 0.33;
        // Altura varía entre 4 y 24
        final height =
            4.0 + 20.0 * (0.5 + 0.5 * math.sin(2 * math.pi * (t + offset)));

        return Container(
          width: 4,
          height: height,
          decoration: BoxDecoration(
            color: widget.color, // Use dynamic color
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}
