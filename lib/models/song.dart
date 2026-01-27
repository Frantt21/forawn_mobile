// lib/models/song.dart
import 'dart:io';

/// Modelo para una canción
class Song {
  final String id; // Hash único basado en filePath
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String filePath; // Ruta completa al archivo MP3
  final String? artworkPath; // Ruta al archivo de imagen cacheado
  final String? artworkUri; // URI original (content://)

  final int? trackNumber;
  final String? year;
  final String? genre;
  final int? dominantColor; // Color dominante del artwork (cacheado)

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    required this.filePath,
    this.artworkPath,
    this.artworkUri,
    this.trackNumber,
    this.year,
    this.genre,
    this.dominantColor,
  });

  /// Crear Song desde archivo MP3
  static Future<Song?> fromFile(File file) async {
    try {
      if (!await file.exists()) return null;

      final fileName = file.path.split('/').last.replaceAll('.mp3', '');
      String title = fileName;
      String artist = 'Unknown Artist';

      if (fileName.contains(' - ')) {
        final parts = fileName.split(' - ');
        if (parts.length >= 2) {
          title = parts[0].trim();
          artist = parts.sublist(1).join(' - ').trim();
        }
      }

      final id = file.path.hashCode.toString();

      return Song(id: id, title: title, artist: artist, filePath: file.path);
    } catch (e) {
      print('[Song] Error loading from file: $e');
      return null;
    }
  }

  /// Serializar a JSON
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration?.inMilliseconds,
    'filePath': filePath,
    'artworkPath': artworkPath,
    'artworkUri': artworkUri,
    'trackNumber': trackNumber,
    'year': year,
    'genre': genre,
    'dominantColor': dominantColor,
  };

  /// Deserializar desde JSON
  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    duration: json['duration'] != null
        ? Duration(milliseconds: json['duration'] as int)
        : null,
    filePath: json['filePath'] as String,
    artworkPath: json['artworkPath'] as String?,
    artworkUri: json['artworkUri'] as String?,
    trackNumber: json['trackNumber'] as int?,
    year: json['year'] as String?,
    genre: json['genre'] as String?,
    dominantColor: json['dominantColor'] as int?,
  );

  /// Copiar con modificaciones
  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? filePath,
    String? artworkPath,
    String? artworkUri,
    int? trackNumber,
    String? year,
    String? genre,
    int? dominantColor,
  }) => Song(
    id: id ?? this.id,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration ?? this.duration,
    filePath: filePath ?? this.filePath,
    artworkPath: artworkPath ?? this.artworkPath,
    artworkUri: artworkUri ?? this.artworkUri,
    trackNumber: trackNumber ?? this.trackNumber,
    year: year ?? this.year,
    genre: genre ?? this.genre,
    dominantColor: dominantColor ?? this.dominantColor,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song(title: $title, artist: $artist, album: $album)';

  String get displayName => '$artist - $title';

  Future<bool> fileExists() async {
    try {
      return await File(filePath).exists();
    } catch (e) {
      return false;
    }
  }

  Future<int?> getFileSize() async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        return await file.length();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Cargar metadatos completos (incluyendo artwork) desde el archivo
  /// DEPRECATED: Usar MetadataService.loadMetadata() externamente.
  Future<Song> loadMetadata() async {
    return this;
  }
}
