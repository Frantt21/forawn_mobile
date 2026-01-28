// lib/services/simple_audio_player.dart
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';

/// Wrapper simple para audioplayers que es más tolerante con archivos problemáticos
class SimpleAudioPlayer {
  final AudioPlayer _player = AudioPlayer();

  Stream<Duration> get positionStream => _player.onPositionChanged;
  Stream<Duration?> get durationStream => _player.onDurationChanged;
  Stream<PlayerState> get playerStateStream => _player.onPlayerStateChanged;

  Duration get position =>
      _player.state == PlayerState.playing ||
          _player.state == PlayerState.paused
      ? Duration
            .zero // Will be updated via stream
      : Duration.zero;

  bool get playing => _player.state == PlayerState.playing;

  Future<void> setFilePath(String path) async {
    await _player.setSourceDeviceFile(path);
  }

  Future<void> setUrl(String url) async {
    await _player.setSourceUrl(url);
  }

  Future<void> play() async {
    await _player.resume();
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  void dispose() {
    _player.dispose();
  }
}
