// lib/models/song.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_media_metadata/flutter_media_metadata.dart';

/// Modelo para una canción
class Song {
  final String id; // Hash único basado en filePath
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String filePath; // Ruta completa al archivo MP3
  final Uint8List? artworkData; // Artwork embebido en bytes
  final int? trackNumber;
  final String? year;
  final String? genre;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    required this.filePath,
    this.artworkData,
    this.trackNumber,
    this.year,
    this.genre,
  });

  /// Crear Song desde archivo MP3
  /// Nota: Requiere package para leer metadatos (flutter_media_metadata o audiotagger)
  static Future<Song?> fromFile(File file) async {
    try {
      if (!await file.exists()) return null;

      final fileName = file.path.split('/').last.replaceAll('.mp3', '');

      // Por ahora, parsear del nombre de archivo
      // Formato esperado: "Artista - Título.mp3"
      String title = fileName;
      String artist = 'Unknown Artist';

      if (fileName.contains(' - ')) {
        final parts = fileName.split(' - ');
        if (parts.length >= 2) {
          title = parts[0].trim();
          artist = parts.sublist(1).join(' - ').trim();
        }
      }

      // Generar ID único basado en la ruta del archivo
      final id = file.path.hashCode.toString();

      return Song(id: id, title: title, artist: artist, filePath: file.path);

      // TODO: Implementar lectura de metadatos real con package
      // Ejemplo con flutter_media_metadata:
      /*
      final metadata = await MetadataRetriever.fromFile(file);
      
      return Song(
        id: file.path.hashCode.toString(),
        title: metadata.trackName ?? fileName,
        artist: metadata.trackArtistNames?.join(', ') ?? 'Unknown Artist',
        album: metadata.albumName,
        duration: metadata.trackDuration,
        filePath: file.path,
        artworkData: metadata.albumArt,
        trackNumber: metadata.trackNumber,
        year: metadata.year?.toString(),
        genre: metadata.genre,
      );
      */
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
    'artworkData': null, // Optimización: No persistir artwork
    'trackNumber': trackNumber,
    'year': year,
    'genre': genre,
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
    artworkData: null, // No persistir artwork en JSON por tamaño
    trackNumber: json['trackNumber'] as int?,
    year: json['year'] as String?,
    genre: json['genre'] as String?,
  );

  /// Copiar con modificaciones
  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? filePath,
    Uint8List? artworkData,
    int? trackNumber,
    String? year,
    String? genre,
  }) => Song(
    id: id ?? this.id,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration ?? this.duration,
    filePath: filePath ?? this.filePath,
    artworkData: artworkData ?? this.artworkData,
    trackNumber: trackNumber ?? this.trackNumber,
    year: year ?? this.year,
    genre: genre ?? this.genre,
  );

  /// Comparación por ID
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song(title: $title, artist: $artist, album: $album)';

  /// Obtener nombre para mostrar
  String get displayName => '$artist - $title';

  /// Verificar si el archivo existe
  Future<bool> fileExists() async {
    try {
      return await File(filePath).exists();
    } catch (e) {
      return false;
    }
  }

  /// Obtener tamaño del archivo
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
  Future<Song> loadMetadata() async {
    if (filePath.startsWith('content://') || filePath.startsWith('http')) {
      // Por ahora no soportamos lectura de tags profundos en SAF/Web sin cachear archivo
      return this;
    }

    try {
      final metadata = await MetadataRetriever.fromFile(File(filePath));
      if (metadata != null) {
        return copyWith(
          title: metadata.trackName?.isNotEmpty == true
              ? metadata.trackName
              : title,
          artist: metadata.trackArtistNames?.isNotEmpty == true
              ? metadata.trackArtistNames!.first
              : artist,
          album: metadata.albumName,
          year: metadata.year?.toString(),
          genre: metadata.genre,
          artworkData: metadata.albumArt,
          duration: metadata.trackDuration != null
              ? Duration(milliseconds: metadata.trackDuration!)
              : duration,
        );
      }
    } catch (e) {
      print('[Song] Error reading metadata for $filePath: $e');
    }
    return this;
  }
}
