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

  /// Reordena una pista dentro de la cola (drag & drop del panel de cola,
  /// misma lógica que Scrup reorderQueue). Ajusta el índice actual y el
  /// orden shuffle en consecuencia.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _songs.length ||
        newIndex < 0 ||
        newIndex >= _songs.length) {
      return;
    }
    // ReorderableListView entrega newIndex ya consumido (mueve el item a
    // newIndex - 1 si viene después del original); normalizar.
    final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (adjusted == oldIndex) return;

    final moved = _songs.removeAt(oldIndex);
    _songs.insert(adjusted, moved);

    // Actualizar índice de la pista actual si fue movida.
    if (_currentIndex == oldIndex) {
      _currentIndex = adjusted;
    } else if (oldIndex < _currentIndex && adjusted >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && adjusted <= _currentIndex) {
      _currentIndex++;
    }

    // Sincronizar el orden shuffle.
    if (_isShuffle) {
      final movedIdx = _shuffledIndices.removeAt(oldIndex);
      _shuffledIndices.insert(adjusted, movedIdx);
    }
  }

  /// Elimina una pista de la cola. Ajusta el índice actual: si se elimina
  /// la actual, la siguiente pasa a ser la actual (mismo índice); si es
  /// posterior, el índice no cambia; si es anterior, retrocede uno.
  /// Devuelve la canción eliminada (o null si el índice es inválido).
  Song? removeAt(int index) {
    if (index < 0 || index >= _songs.length) return null;
    final removed = _songs.removeAt(index);

    if (_isShuffle) {
      final pos = _shuffledIndices.indexOf(index);
      if (pos != -1) _shuffledIndices.removeAt(pos);
      // Renumerar los índices posteriores al eliminado.
      _shuffledIndices = _shuffledIndices
          .map((i) => i > index ? i - 1 : i)
          .toList();
    }

    if (_currentIndex == index) {
      // La eliminada era la actual: la que ocupa su lugar es la actual.
      if (_currentIndex >= _songs.length) {
        _currentIndex = _songs.isEmpty ? -1 : _songs.length - 1;
      }
    } else if (index < _currentIndex) {
      _currentIndex--;
    }
    return removed;
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

  /// Obtener la siguiente canción sin cambiar el índice actual (para precaching)
  Song? peekNext() {
    final idx = nextIndex;
    return (idx != null && idx >= 0 && idx < _songs.length)
        ? _songs[idx]
        : null;
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
