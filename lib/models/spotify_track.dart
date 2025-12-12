// lib/models/spotify_track.dart
class SpotifyTrack {
  final String title;
  final String duration;
  final String popularity;
  final String url;
  final String artists; // nuevo

  SpotifyTrack({
    required this.title,
    required this.duration,
    required this.popularity,
    required this.url,
    required this.artists,
  });

  factory SpotifyTrack.fromJson(Map<String, dynamic> json) {
    String string(dynamic v) {
      if (v == null) return '';
      if (v is String) return v;
      if (v is List) return v.join(', ');
      return v.toString();
    }

    final title = string(json['title'] ?? json['name'] ?? json['track'] ?? json['song']);
    final duration = string(json['duration'] ?? json['duration_ms'] ?? json['length'] ?? json['time']);
    final popularity = string(json['popularity'] ?? json['score'] ?? json['rating'] ?? '');
    final url = string(json['url'] ?? json['link'] ?? json['track_url'] ?? json['spotify_url']);

    // Intentos para extraer artistas
    String artists = '';
    if (json.containsKey('artists')) {
      final a = json['artists'];
      if (a is String) {
        artists = a;
      } else if (a is List) artists = a.map((e) => e.toString()).join(', ');
      else if (a is Map && a['name'] != null) artists = a['name'].toString();
    }
    if (artists.isEmpty) {
      artists = string(json['artist'] ?? json['artists_names'] ?? json['album'] ?? '');
    }

    return SpotifyTrack(
      title: title,
      duration: duration,
      popularity: popularity,
      url: url,
      artists: artists,
    );
  }
}
