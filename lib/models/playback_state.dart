// lib/models/playback_state.dart

/// Modos de repetición
enum RepeatMode { off, all, one }

extension RepeatModeExtension on RepeatMode {
  String get icon {
    switch (this) {
      case RepeatMode.off:
        return '➡️';
      case RepeatMode.all:
        return '🔁';
      case RepeatMode.one:
        return '🔂';
    }
  }
}

/// Estado de reproducción
enum PlayerState {
  idle, // Sin canción cargada
  loading, // Cargando canción
  playing, // Reproduciendo
  paused, // Pausado
  buffering, // Buffering
  completed, // Canción completada
  error, // Error
}

extension PlayerStateExtension on PlayerState {
  bool get isPlaying => this == PlayerState.playing;
  bool get isPaused => this == PlayerState.paused;
  bool get isLoading =>
      this == PlayerState.loading || this == PlayerState.buffering;
  bool get canPlay =>
      this == PlayerState.paused ||
      this == PlayerState.idle ||
      this == PlayerState.completed;
  bool get canPause => this == PlayerState.playing;
}

/// Historial de reproducción (para navegación hacia atrás)
class PlaybackHistory {
  final List<String> _history = []; // IDs de canciones
  static const int maxHistorySize = 10;

  PlaybackHistory(); // Constructor vacío explícito

  /// Agregar canción al historial
  void add(String songId) {
    // Remover si ya existe para evitar duplicados consecutivos
    _history.remove(songId);

    // Agregar al final
    _history.add(songId);

    // Mantener solo las últimas N canciones
    if (_history.length > maxHistorySize) {
      _history.removeAt(0);
    }
  }

  /// Obtener la canción anterior (sin removerla)
  String? getPrevious() {
    if (_history.length < 2) return null;
    // Retornar la penúltima (la última es la actual)
    return _history[_history.length - 2];
  }

  /// Retroceder en el historial (remover la actual y retornar la anterior)
  String? goBack() {
    if (_history.length < 2) return null;

    // Remover la canción actual
    _history.removeLast();

    // Retornar la nueva última (que era la anterior)
    return _history.last;
  }

  /// Obtener la canción actual
  String? get current => _history.isEmpty ? null : _history.last;

  /// Limpiar historial
  void clear() => _history.clear();

  /// Tamaño del historial
  int get length => _history.length;

  /// Verificar si se puede retroceder
  bool get canGoBack => _history.length >= 2;

  /// Obtener todo el historial (para debug)
  List<String> get all => List.unmodifiable(_history);

  /// Serializar a JSON
  Map<String, dynamic> toJson() => {'history': _history};

  /// Deserializar desde JSON
  factory PlaybackHistory.fromJson(Map<String, dynamic> json) {
    final history = PlaybackHistory();
    final list = json['history'] as List?;
    if (list != null) {
      history._history.addAll(list.cast<String>());
    }
    return history;
  }
}

/// Información de progreso de reproducción
class PlaybackProgress {
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;

  PlaybackProgress({
    required this.position,
    required this.duration,
    required this.bufferedPosition,
  });

  /// Progreso como porcentaje (0.0 - 1.0)
  double get percentage {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Progreso buffered como porcentaje (0.0 - 1.0)
  double get bufferedPercentage {
    if (duration.inMilliseconds == 0) return 0.0;
    return (bufferedPosition.inMilliseconds / duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  /// Tiempo restante
  Duration get remaining => duration - position;

  /// Formatear posición como mm:ss
  String get formattedPosition {
    final minutes = position.inMinutes;
    final seconds = position.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Formatear duración como mm:ss
  String get formattedDuration {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Formatear tiempo restante como mm:ss
  String get formattedRemaining {
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '-${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  PlaybackProgress copyWith({
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
  }) => PlaybackProgress(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
  );

  static PlaybackProgress zero() => PlaybackProgress(
    position: Duration.zero,
    duration: Duration.zero,
    bufferedPosition: Duration.zero,
  );
}
