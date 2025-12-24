import 'song.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? imagePath;
  final DateTime createdAt;
  final bool isPinned;
  final List<Song> songs;

  Playlist({
    required this.id,
    required this.name,
    this.description,
    this.imagePath,
    required this.createdAt,
    this.isPinned = false,
    required this.songs,
  });

  Playlist copyWith({
    String? name,
    String? description,
    String? imagePath,
    bool? isPinned,
    List<Song>? songs,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      imagePath: imagePath ?? this.imagePath,
      createdAt: createdAt,
      isPinned: isPinned ?? this.isPinned,
      songs: songs ?? this.songs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'imagePath': imagePath,
    'createdAt': createdAt.toIso8601String(),
    'isPinned': isPinned,
    'songs': songs.map((s) => s.toJson()).toList(),
  };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    imagePath: json['imagePath'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    isPinned: json['isPinned'] as bool? ?? false,
    songs:
        (json['songs'] as List<dynamic>?)
            ?.map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );
}
