// lib/services/youtube_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class YouTubeVideo {
  final String id;
  final String title;
  final String url;
  final int duration;
  final String durationText;
  final String thumbnail;
  final String author;
  final String parsedArtist;
  final String parsedSong;

  YouTubeVideo({
    required this.id,
    required this.title,
    required this.url,
    required this.duration,
    required this.durationText,
    required this.thumbnail,
    required this.author,
    required this.parsedArtist,
    required this.parsedSong,
  });

  factory YouTubeVideo.fromJson(Map<String, dynamic> json) {
    return YouTubeVideo(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      duration: json['duration'] ?? 0,
      durationText: json['durationText'] ?? '0:00',
      thumbnail: json['thumbnail'] ?? '',
      author: json['author'] ?? 'Unknown',
      parsedArtist: json['parsedArtist'] ?? '',
      parsedSong: json['parsedSong'] ?? '',
    );
  }

  String get displayTitle {
    if (parsedArtist.isNotEmpty && parsedSong.isNotEmpty) {
      return parsedSong;
    }
    return title;
  }

  String get displayArtist {
    if (parsedArtist.isNotEmpty) {
      return parsedArtist;
    }
    return author;
  }
}

class CachedSong {
  final bool cached;
  final String? downloadUrl;
  final Map<String, dynamic>? metadata;
  final Map<String, dynamic>? cacheInfo;

  CachedSong({
    required this.cached,
    this.downloadUrl,
    this.metadata,
    this.cacheInfo,
  });

  factory CachedSong.fromJson(Map<String, dynamic> json) {
    return CachedSong(
      cached: json['cached'] ?? false,
      downloadUrl: json['downloadUrl'],
      metadata: json['metadata'],
      cacheInfo: json['cacheInfo'],
    );
  }
}

class YouTubeService {
  /// Buscar videos en YouTube
  Future<List<YouTubeVideo>> search(String query, {int limit = 40}) async {
    try {
      final url = ApiConfig.getYouTubeSearchUrl(query, limit: limit);
      final uri = Uri.parse(url);

      print('[YouTubeService] Searching: $query');

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = (data['results'] as List)
            .map((v) => YouTubeVideo.fromJson(v))
            .toList();

        print('[YouTubeService] Found ${results.length} results');
        return results;
      } else {
        print('[YouTubeService] Error: ${response.statusCode}');
        throw Exception('Failed to search YouTube: ${response.statusCode}');
      }
    } catch (e) {
      print('[YouTubeService] Exception: $e');
      rethrow;
    }
  }

  /// Verificar si una canción está en caché
  Future<CachedSong> checkCache(String title, String artist) async {
    try {
      final url = ApiConfig.getCacheCheckUrl(title, artist);
      final uri = Uri.parse(url);

      print('[YouTubeService] Checking cache: $title by $artist');

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final cachedSong = CachedSong.fromJson(data);

        if (cachedSong.cached) {
          print('[YouTubeService] ✓ Cache HIT');
        } else {
          print('[YouTubeService] Cache MISS');
        }

        return cachedSong;
      } else {
        print('[YouTubeService] Error checking cache: ${response.statusCode}');
        return CachedSong(cached: false);
      }
    } catch (e) {
      print('[YouTubeService] Exception checking cache: $e');
      return CachedSong(cached: false);
    }
  }

  /// Obtener estadísticas del caché
  Future<Map<String, dynamic>?> getCacheStats() async {
    try {
      final uri = Uri.parse(ApiConfig.getCacheStatsUrl());
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('[YouTubeService] Error getting cache stats: $e');
      return null;
    }
  }

  /// Limpiar caché manualmente
  Future<Map<String, dynamic>?> cleanupCache() async {
    try {
      final uri = Uri.parse(ApiConfig.getCacheCleanupUrl());
      final response = await http.post(uri);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('[YouTubeService] Error cleaning cache: $e');
      return null;
    }
  }

  /// Obtener cuota de Google Drive
  Future<Map<String, dynamic>?> getDriveQuota() async {
    try {
      final uri = Uri.parse(ApiConfig.getDriveQuotaUrl());
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('[YouTubeService] Error getting drive quota: $e');
      return null;
    }
  }

  /// Formatear bytes a formato legible
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
