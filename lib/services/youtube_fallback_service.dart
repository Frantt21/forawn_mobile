// lib/services/youtube_fallback_service.dart
// Versión con APIs actualizadas y funcionales
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';

class YoutubeFallbackService {
  final YoutubeExplode _yt = YoutubeExplode();
  final Dio _dio = Dio();

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  String _buildQuery({required String trackTitle, required String artistName}) {
    final t = trackTitle.trim();
    final a = artistName.trim();

    if (a.isNotEmpty && t.isNotEmpty) return '$a - $t official audio';
    if (t.isNotEmpty) return '$t official audio';
    if (a.isNotEmpty) return '$a official audio';
    return 'official audio';
  }

  Future<Video?> _searchYoutubeVideo(
    String trackTitle,
    String artistName,
  ) async {
    final query = _buildQuery(trackTitle: trackTitle, artistName: artistName);
    print('[YoutubeFallback] Buscando en YouTube: "$query"');

    try {
      final searchList = await _yt.search
          .search(query)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              throw TimeoutException('Búsqueda timeout');
            },
          );

      if (searchList.isEmpty) {
        print('[YoutubeFallback] No se encontraron resultados');
        return null;
      }

      final video = searchList.first;
      print('[YoutubeFallback] Video encontrado: ${video.title}');
      print('[YoutubeFallback] Video ID: ${video.id.value}');
      return video;
    } catch (e) {
      print('[YoutubeFallback] Error buscando: $e');
      return null;
    }
  }

  /// Obtener URL usando APIs públicas actualizadas
  /// Orden: 1) Foranly, 2) Dorratz, 3) RapidAPI, 4) YT Search, 5) YT MP3 2025, 6) YT CDN
  Future<String?> _getDownloadUrlFromApi(String videoId) async {
    final videoUrl = 'https://www.youtube.com/watch?v=$videoId';

    // OPCIÓN 1: Foranly API (Custom - Asíncrono)
    try {
      print('[YoutubeFallback] [1/6] Intentando Foranly API (Async)...');
      final startUrl =
          'http://api.foranly.space:24725/download?url=$videoUrl&format=audio';
      print('[YoutubeFallback] Iniciando Job: $startUrl');

      final startResp = await http
          .get(Uri.parse(startUrl))
          .timeout(const Duration(seconds: 15));

      print(
        '[YoutubeFallback] Start Resp: ${startResp.statusCode} ${startResp.body}',
      );

      if (startResp.statusCode == 200) {
        final startData = json.decode(startResp.body);
        final jobId = startData['jobId'];

        if (jobId != null) {
          print('[YoutubeFallback] Job ID: $jobId. Esperando conversión...');

          // Conectarse al SSE para esperar el estado 'ready'
          final sseReq = http.Request(
            'GET',
            Uri.parse('http://api.foranly.space:24725/progress/$jobId'),
          );

          final sseResp = await sseReq.send();
          final completer = Completer<String?>();
          StreamSubscription? sub;

          // Timeout de seguridad de 2 min para el proceso del backend
          final timer = Timer(const Duration(minutes: 2), () {
            sub?.cancel();
            if (!completer.isCompleted) completer.complete(null);
            print('[YoutubeFallback] Foranly Timeout esperando SSE');
          });

          sub = sseResp.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (line.startsWith('data: ')) {
                    try {
                      final jsonStr = line.substring(6);
                      final d = json.decode(jsonStr);
                      final status = d['status'];

                      if (status == 'ready') {
                        print('[YoutubeFallback] ✓ Foranly Job READY');
                        sub?.cancel();
                        timer.cancel();
                        // Construir URL final
                        final dlUrl =
                            'http://api.foranly.space:24725/download-file/$jobId';
                        if (!completer.isCompleted) completer.complete(dlUrl);
                      } else if (status == 'error') {
                        print(
                          '[YoutubeFallback] Foranly Error: ${d['message']}',
                        );
                        sub?.cancel();
                        timer.cancel();
                        if (!completer.isCompleted) completer.complete(null);
                      } else if (status == 'downloading') {
                        // Opcional: Log de progreso del backend
                        // print('[YoutubeFallback] Backend progress: ${d['progress']}%');
                      }
                    } catch (_) {}
                  }
                },
                onError: (e) {
                  print('[YoutubeFallback] SSE Error: $e');
                  if (!completer.isCompleted) completer.complete(null);
                },
              );

          final downloadUrl = await completer.future;
          if (downloadUrl != null) {
            print('[YoutubeFallback] ✓ Foranly Flow Completo');
            print('✅ [API SUCCESS] Usando API: Foranly API (Async)');
            return downloadUrl;
          }
        }
      }
    } catch (e) {
      print('[YoutubeFallback] Foranly API falló: $e');
    }

    // OPCIÓN 2: API de Dorratz (ytmp3.nu - muy estable)
    try {
      print('[YoutubeFallback] [2/6] Intentando Dorratz API...');

      final response = await http
          .post(
            Uri.parse('https://ytmp3.nu/api/ajaxSearch'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'Mozilla/5.0',
            },
            body: {'q': videoUrl, 'vt': 'mp3'},
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['links'] != null && data['links']['mp3'] != null) {
          final mp3Links = data['links']['mp3'] as Map<String, dynamic>;

          for (final quality in ['mp3128', '128', 'auto']) {
            if (mp3Links[quality]?['k'] != null) {
              final convertResp = await http
                  .post(
                    Uri.parse('https://ytmp3.nu/api/ajaxConvert'),
                    headers: {
                      'Content-Type': 'application/x-www-form-urlencoded',
                    },
                    body: {'vid': videoId, 'k': mp3Links[quality]['k']},
                  )
                  .timeout(const Duration(seconds: 25));

              if (convertResp.statusCode == 200) {
                final convertData = json.decode(convertResp.body);
                if (convertData['dlink'] != null) {
                  print('[YoutubeFallback] ✓ Dorratz API OK');
                  print('✅ [API SUCCESS] Usando API: Dorratz (ytmp3.nu)');
                  return convertData['dlink'];
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('[YoutubeFallback] Dorratz API falló: $e');
    }

    // OPCIÓN 3: RapidAPI YouTube to MP3
    try {
      print('[YoutubeFallback] [3/6] Intentando RapidAPI...');

      final response = await http
          .get(
            Uri.parse('https://youtube-mp36.p.rapidapi.com/dl?id=$videoId'),
            headers: {
              'x-rapidapi-key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
              'x-rapidapi-host': 'youtube-mp36.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['link'] != null && data['link'].toString().isNotEmpty) {
          print('[YoutubeFallback] ✓ RapidAPI OK');
          print('✅ [API SUCCESS] Usando API: RapidAPI YouTube MP3');
          return data['link'];
        }
      }
    } catch (e) {
      print('[YoutubeFallback] RapidAPI falló: $e');
    }

    // OPCIÓN 4: YT Search and Download MP3 (NUEVA)
    try {
      print('[YoutubeFallback] [4/6] Intentando YT Search & Download API...');

      final response = await http
          .get(
            Uri.parse(
              'https://yt-search-and-download-mp3.p.rapidapi.com/mp3?url=$videoUrl',
            ),
            headers: {
              'X-Rapidapi-Key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
              'X-Rapidapi-Host': 'yt-search-and-download-mp3.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['download'] != null) {
          print('[YoutubeFallback] ✓ YT Search API OK');
          print('✅ [API SUCCESS] Usando API: YT Search & Download');
          return data['download'];
        }
      }
    } catch (e) {
      print('[YoutubeFallback] YT Search API falló: $e');
    }

    // OPCIÓN 5: YouTube MP3 2025 (NUEVA)
    try {
      print('[YoutubeFallback] [5/6] Intentando YouTube MP3 2025 API...');

      final response = await http
          .get(
            Uri.parse(
              'https://youtube-mp3-2025.p.rapidapi.com/v1/social/youtube/audio?id=$videoId&quality=128kbps&ext=mp3',
            ),
            headers: {
              'X-Rapidapi-Key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
              'X-Rapidapi-Host': 'youtube-mp3-2025.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['linkDownload'] != null) {
          print('[YoutubeFallback] ✓ YouTube MP3 2025 API OK');
          print('✅ [API SUCCESS] Usando API: YouTube MP3 2025');
          return data['linkDownload'];
        }
      }
    } catch (e) {
      print('[YoutubeFallback] YouTube MP3 2025 API falló: $e');
    }

    // OPCIÓN 6: YouTube CDN API (NUEVA - Requiere ID)
    try {
      print('[YoutubeFallback] [6/6] Intentando YouTube CDN API...');

      final response = await http
          .get(
            Uri.parse(
              'https://youtube-mp4-mp3-m4a-cdn.p.rapidapi.com/audio?ext=mp3&id=$videoId&quality=128kbps',
            ),
            headers: {
              'X-Rapidapi-Key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
              'X-Rapidapi-Host': 'youtube-mp4-mp3-m4a-cdn.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['linkDownload'] != null) {
          print('[YoutubeFallback] ✓ YouTube CDN API OK');
          print('✅ [API SUCCESS] Usando API: YouTube CDN API');
          return data['linkDownload'];
        }
      }
    } catch (e) {
      print('[YoutubeFallback] YouTube CDN API falló: $e');
    }

    print('[YoutubeFallback] ✗ Todas las APIs fallaron');
    return null;
  }

  Future<String?> downloadAudioFromYoutube({
    required String trackTitle,
    required String artistName,
    required Function(double) onProgress,
  }) async {
    File? file;

    print('═══════════════════════════════════════════════════════');
    print('🎵 YOUTUBE FALLBACK ACTIVADO');
    print('Track: $trackTitle');
    print('Artist: $artistName');
    print('═══════════════════════════════════════════════════════');

    try {
      // 1. Buscar video
      final video = await _searchYoutubeVideo(trackTitle, artistName);
      if (video == null) {
        return null;
      }

      // 2. Obtener URL
      final downloadUrl = await _getDownloadUrlFromApi(video.id.value);
      if (downloadUrl == null) {
        print('[YoutubeFallback] No se pudo obtener URL');
        return null;
      }

      print(
        '[YoutubeFallback] Descargando desde: ${downloadUrl.substring(0, downloadUrl.length > 50 ? 50 : downloadUrl.length)}...',
      );

      // 3. Preparar archivo
      final tempDir = await getTemporaryDirectory();
      final fileName = _sanitizeFileName('${trackTitle}_$artistName.mp3');
      final tempPath = '${tempDir.path}/$fileName';
      file = File(tempPath);

      if (await file.exists()) {
        await file.delete();
      }

      // 4. Descargar
      await _dio.download(
        downloadUrl,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            if (progress % 0.1 < 0.02 || progress > 0.98) {
              print(
                '[YoutubeFallback] ${(progress * 100).toStringAsFixed(0)}% (${(received / 1024 / 1024).toStringAsFixed(2)} MB)',
              );
            }
            onProgress(progress);
          } else {
            if (received % (500 * 1024) == 0) {
              print(
                '[YoutubeFallback] Descargado: ${(received / 1024 / 1024).toStringAsFixed(2)} MB',
              );
            }
            onProgress(0.5);
          }
        },
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': '*/*',
            'Referer': 'https://www.youtube.com/',
          },
          receiveTimeout: const Duration(minutes: 5),
          followRedirects: true,
          maxRedirects: 10,
          validateStatus: (status) => status! < 500,
        ),
      );

      // 5. Verificar
      if (!await file.exists()) {
        throw Exception('Archivo no creado');
      }

      final fileSize = await file.length();
      if (fileSize < 10000) {
        throw Exception('Archivo muy pequeño: $fileSize bytes');
      }

      print(
        '[YoutubeFallback] ✓ Completo: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB',
      );
      onProgress(1.0);
      return tempPath;
    } on DioException catch (e) {
      print('[YoutubeFallback] Error Dio: ${e.type} - ${e.message}');
      if (e.response != null) {
        print('[YoutubeFallback] Status: ${e.response?.statusCode}');
      }
      if (file != null && await file.exists()) await file.delete();
      return null;
    } catch (e, st) {
      print('[YoutubeFallback] Error: $e');
      print(st);
      if (file != null && await file.exists()) await file.delete();
      return null;
    }
  }

  void dispose() {
    _yt.close();
    _dio.close();
  }
}
