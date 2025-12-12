import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

/// Modelo para resultado de Pinterest
class PinterestImage {
  final String? imageLargeUrl;
  final String? imageMediumUrl;
  final String? imageSmallUrl;

  PinterestImage({this.imageLargeUrl, this.imageMediumUrl, this.imageSmallUrl});

  factory PinterestImage.fromJson(Map<String, dynamic> json) {
    return PinterestImage(
      imageLargeUrl: json['image_large_url'] as String?,
      imageMediumUrl: json['image_medium_url'] as String?,
      imageSmallUrl: json['image_small_url'] as String?,
    );
  }

  /// Obtener la mejor URL disponible
  String? get bestUrl => imageLargeUrl ?? imageSmallUrl ?? imageMediumUrl;
}

/// Servicio para buscar imágenes en Pinterest
class PinterestService {
  /// Buscar imágenes en Pinterest
  static Future<List<PinterestImage>> searchImages(String query) async {
    try {
      final url = Uri.parse(ApiConfig.getPinterestSearchUrl(query));
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final dynamic jsonResponse = jsonDecode(response.body);

        // La respuesta puede ser directamente una lista o estar en un campo 'data'
        List<dynamic> imagesList;

        if (jsonResponse is List) {
          imagesList = jsonResponse;
        } else if (jsonResponse is Map && jsonResponse['data'] is List) {
          imagesList = jsonResponse['data'];
        } else if (jsonResponse is Map && jsonResponse['results'] is List) {
          imagesList = jsonResponse['results'];
        } else {
          print('[PinterestService] Unexpected response format');
          return [];
        }

        return imagesList
            .map(
              (json) => PinterestImage.fromJson(json as Map<String, dynamic>),
            )
            .where((img) => img.bestUrl != null)
            .toList();
      }

      print('[PinterestService] Error: ${response.statusCode}');
      return [];
    } catch (e) {
      print('[PinterestService] Error searching images: $e');
      return [];
    }
  }

  /// Obtener la primera imagen de una búsqueda (para portadas)
  static Future<String?> getFirstImage(String query) async {
    try {
      final images = await searchImages(query);
      return images.isNotEmpty ? images.first.bestUrl : null;
    } catch (e) {
      print('[PinterestService] Error getting first image: $e');
      return null;
    }
  }

  /// Buscar portada de canción (optimizado para música)
  static Future<String?> getSongCover(
    String songName,
    String artistName,
  ) async {
    // Construir query optimizada para portadas de música
    final query = '$artistName $songName portada';
    return await getFirstImage(query);
  }
}
