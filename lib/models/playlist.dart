// lib/models/playlist.dart
import 'dart:math';
import 'song.dart';
import 'playback_state.dart';

class Playlist {
  final String name;
  final List<Song> _songs = [];
  List<int> _shuffledIndices = [];
  int _currentIndex = -1;

  // Separated states
  bool _isShuffle = false;
  RepeatMode _repeatMode = RepeatMode.off;

  Playlist({required this.name, List<Song>? songs}) {
    if (songs != null) {
      _songs.addAll(songs);
      _resetShuffledIndices();
    }
  }

  // Getters
  List<Song> get songs => List.unmodifiable(_songs);
  int get length => _songs.length;
  bool get isEmpty => _songs.isEmpty;
  bool get isNotEmpty => _songs.isNotEmpty;
  int get currentIndex => _currentIndex;
  Song? get currentSong => (_currentIndex >= 0 && _currentIndex < _songs.length)
      ? _songs[_currentIndex]
      : null;

  bool get isShuffle => _isShuffle;
  RepeatMode get repeatMode => _repeatMode;

  // Setters
  void setShuffle(bool enable) {
    if (_isShuffle == enable) return;
    _isShuffle = enable;

    if (_isShuffle) {
      _generateShuffleOrder();
    } else {
      _resetShuffledIndices();
    }
  }

  void setRepeatMode(RepeatMode mode) {
    _repeatMode = mode;
  }

  // Gestión de canciones
  void add(Song song) {
    _songs.add(song);
    if (_isShuffle) {
      final newIndex = _songs.length - 1;
      final remaining = _shuffledIndices.sublist(_currentIndex + 1);
      final visited = _shuffledIndices.sublist(0, _currentIndex + 1);

      remaining.add(newIndex);
      remaining.shuffle();

      _shuffledIndices = [...visited, ...remaining];
    } else {
      _shuffledIndices.add(_songs.length - 1);
    }
  }

  void addAll(List<Song> newSongs) {
    for (var song in newSongs) {
      add(song);
    }
  }

  void clear() {
    _songs.clear();
    _shuffledIndices.clear();
    _currentIndex = -1;
  }

  // Navegación
  void setCurrentIndex(int index) {
    if (index >= 0 && index < _songs.length) {
      _currentIndex = index;
    }
  }

  /// Selecciona una canción específica (ej: tap en lista)
  void selectSong(Song song) {
    final index = _songs.indexOf(song);
    if (index != -1) {
      _currentIndex = index;
      if (_isShuffle) {
        // Regenerar shuffle para que esta sea la actual, o simplemente encontrarla?
        // Mejor regenerar para fresh shuffle
        _generateShuffleOrder(startingIndex: index);
      }
    }
  }

  /// Obtener índice de la siguiente canción
  int? get nextIndex {
    if (_songs.isEmpty) return null;
    if (_currentIndex == -1) return 0;

    // Repeat One siempre devuelve la misma
    if (_repeatMode == RepeatMode.one) {
      return _currentIndex;
    }

    if (_isShuffle) {
      final currentShufflePos = _shuffledIndices.indexOf(_currentIndex);
      if (currentShufflePos == -1) return null; // Error state

      if (currentShufflePos + 1 < _shuffledIndices.length) {
        return _shuffledIndices[currentShufflePos + 1];
      } else if (_repeatMode == RepeatMode.all) {
        return _shuffledIndices[0]; // Loop back shuffle
      }
      return null; // Fin
    } else {
      // Normal
      if (_currentIndex + 1 < _songs.length) {
        return _currentIndex + 1;
      } else if (_repeatMode == RepeatMode.all) {
        return 0; // Loop back normal
      }
      return null; // Fin
    }
  }

  /// Obtener índice de la canción anterior
  int? get previousIndex {
    if (_songs.isEmpty) return null;
    if (_currentIndex == -1) return null;

    if (_repeatMode == RepeatMode.one) {
      return _currentIndex;
    }

    if (_isShuffle) {
      final currentShufflePos = _shuffledIndices.indexOf(_currentIndex);
      if (currentShufflePos > 0) {
        return _shuffledIndices[currentShufflePos - 1];
      } else if (_repeatMode == RepeatMode.all) {
        return _shuffledIndices.last;
      }
      // Si estamos al inicio, volver al inicio o null? Null es stop/inicio.
      // O podríamos hacer wrap around siempre con previous? No, es mejor standard.
      // Si Repeat=Off, previous en primera canción suele ir a Inicio de canción, no anterior.
      // Eso lo maneja el AudioPlayerService (seek 0). Aquí devolvemos null si no hay anterior.
      return null;
    } else {
      if (_currentIndex > 0) {
        return _currentIndex - 1;
      } else if (_repeatMode == RepeatMode.all) {
        return _songs.length - 1;
      }
      return null;
    }
  }

  // Lógica Interna
  void updateCurrentSong(Song updatedSong) {
    if (_currentIndex >= 0 && _currentIndex < _songs.length) {
      _songs[_currentIndex] = updatedSong;
    }
  }

  void _resetShuffledIndices() {
    _shuffledIndices = List.generate(_songs.length, (i) => i);
  }

  void _generateShuffleOrder({int? startingIndex}) {
    List<int> indices = List.generate(_songs.length, (i) => i);

    int start = startingIndex ?? _currentIndex;
    if (start != -1 && start < indices.length) {
      indices.remove(start);
    } else {
      start = -1;
    }

    indices.shuffle(Random());

    if (start != -1) {
      indices.insert(0, start);
    }

    _shuffledIndices = indices;
  }
}
