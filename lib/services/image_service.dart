// lib/services/image_service.dart
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../config/api_config.dart';

class ImageService {
  final Dio _dio = Dio();

  /// Llama al endpoint de generación y devuelve el image_link (o null)
  Future<String?> generateImage({
    required String prompt,
    required String ratio,
  }) async {
    try {
      final url = ApiConfig.getImageGenerationUrl(prompt, ratio);
      final resp = await _dio.get(url).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data;
        // Manejo defensivo: la estructura que mostraste es { "CREATOR": "...", "data": { "image_link": "...", ... } }
        if (data is Map &&
            data['data'] is Map &&
            data['data']['image_link'] != null) {
          return data['data']['image_link'] as String;
        }
      }
      return null;
    } catch (e) {
      print('[ImageService] generateImage error: $e');
      return null;
    }
  }

  /// Descarga la URL a un archivo temporal y devuelve la ruta local
  Future<String?> downloadToTemp(
    String url,
    Function(double) onProgress,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = url.split('/').last.split('?').first;
      final tempPath = '${tempDir.path}/$fileName';

      await _dio.download(
        url,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress(received / total);
          } else {
            onProgress(0);
          }
        },
        options: Options(
          receiveTimeout: Duration.zero,
          sendTimeout: Duration.zero,
        ),
      );

      return tempPath;
    } catch (e) {
      print('[ImageService] downloadToTemp error: $e');
      return null;
    }
  }

  void dispose() {
    _dio.close(force: true);
  }
}
