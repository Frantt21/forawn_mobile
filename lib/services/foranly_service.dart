// lib/services/foranly_service.dart
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class ForanlyService {
  /// Obtener URL de descarga buscando por Query (Título - Artista)
  /// Retorna la URL de descarga directa o null si falla
  Future<String?> getDownloadUrlWait(String query) async {
    // 1. Intentar con servidor primario
    try {
      final url = await _tryGetUrl(ApiConfig.foranlyBackendPrimary, query);
      if (url != null) return url;
    } catch (e) {
      print('[ForanlyService] Error en primario: $e');
    }

    // 2. Intentar con servidor de respaldo
    try {
      final url = await _tryGetUrl(ApiConfig.foranlyBackendBackup, query);
      if (url != null) return url;
    } catch (e) {
      print('[ForanlyService] Error en backup: $e');
    }

    return null;
  }

  /// Método auxiliar privado para intentar obtener la URL
  Future<String?> _tryGetUrl(String baseUrl, String query) async {
    // 1. Buscar Video ID
    final searchUrl =
        '$baseUrl/youtube/search?q=${Uri.encodeComponent(query)}&limit=1';
    print('[ForanlyService] Buscando en: $searchUrl');

    final searchResponse = await http
        .get(Uri.parse(searchUrl))
        .timeout(const Duration(seconds: 10));

    if (searchResponse.statusCode != 200) {
      print('[ForanlyService] Error búsqueda: ${searchResponse.statusCode}');
      return null;
    }

    final searchData = json.decode(searchResponse.body);
    if (searchData['results'] == null ||
        (searchData['results'] as List).isEmpty) {
      print('[ForanlyService] No se encontraron resultados');
      return null;
    }

    final String? videoId = searchData['results'][0]['id'];
    if (videoId == null) return null;

    // 2. Iniciar Trabajo de Conversión/Descarga
    final downloadEndpoint =
        '$baseUrl/download?url=https://youtube.com/watch?v=$videoId&format=audio&enrich=true&query=${Uri.encodeComponent(query)}';
    print('[ForanlyService] Iniciando job: $downloadEndpoint');

    final jobResponse = await http
        .get(Uri.parse(downloadEndpoint))
        .timeout(const Duration(seconds: 15));

    if (jobResponse.statusCode != 200) {
      print('[ForanlyService] Error al iniciar job: ${jobResponse.statusCode}');
      return null;
    }

    final jobData = json.decode(jobResponse.body);
    final String? jobId = jobData['jobId'];

    if (jobId == null) {
      print('[ForanlyService] No se recibió jobId');
      return null;
    }

    print('[ForanlyService] Job iniciado: $jobId. Conectando a SSE stream...');

    // 3. Consumir SSE Stream (Server-Sent Events)
    final client = http.Client();
    final progressUrl = '$baseUrl/progress/$jobId';

    try {
      final request = http.Request('GET', Uri.parse(progressUrl));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10)); // Timeout solo para conectar

      final completer = Completer<String?>();

      // Escuchar el stream línea por línea
      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line.startsWith('data: ')) {
                final jsonStr = line.substring(6); // Remover "data: "
                try {
                  final data = json.decode(jsonStr);
                  final status = data['status'];
                  final progress = data['progress'] ?? 0;

                  // print('[ForanlyService] SSE Stream: $status ($progress%)');

                  if (status == 'ready' || status == 'complete') {
                    if (!completer.isCompleted) {
                      print('[ForanlyService] Job completado (SSE).');
                      completer.complete('$baseUrl/download-file/$jobId');
                    }
                  } else if (status == 'error') {
                    if (!completer.isCompleted) {
                      print(
                        '[ForanlyService] Job error (SSE): ${data['message']}',
                      );
                      completer.complete(null);
                    }
                  }
                } catch (_) {}
              }
            },
            onError: (e) {
              print('[ForanlyService] SSE Error: $e');
              if (!completer.isCompleted) completer.complete(null);
            },
            onDone: () {
              if (!completer.isCompleted) {
                print('[ForanlyService] SSE Stream cerrado sin completar.');
                completer.complete(null);
              }
            },
          );

      // Retornar el futuro del completer (esperar a que el stream nos dé el resultado)
      // Timeout de seguridad global para el proceso entero (5 min)
      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          print('[ForanlyService] Timeout global esperando SSE');
          client.close();
          return null;
        },
      );
    } catch (e) {
      print('[ForanlyService] Error conectando a SSE: $e');
      client.close();
      return null;
    } finally {
      // client.close(); // No cerrar inmediatamente, el stream listener lo necesita
      // Se cerrará al completar o timeout
    }
  }
}
