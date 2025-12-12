import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/spotify_track.dart';
import '../models/download_info.dart';
import '../config/api_config.dart';

class SpotifyService {
  // RapidAPI Key
  static const String _rapidApiKey =
      '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0';

  /// Search for songs on Spotify (robust parsing + logs)
  Future<List<SpotifyTrack>> searchSongs(String query) async {
    final url = Uri.parse(ApiConfig.getSpotifySearchUrl(query));

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 12));

      print('[SpotifyService] searchSongs status=${response.statusCode}');
      print('[SpotifyService] searchSongs body=${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Error en la búsqueda: ${response.statusCode}');
      }

      dynamic jsonResponse;
      try {
        jsonResponse = json.decode(response.body);
      } catch (e) {
        final trimmed = response.body.trim();
        if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
          final unquoted = trimmed.substring(1, trimmed.length - 1);
          try {
            jsonResponse = json.decode(unquoted);
          } catch (e2) {
            throw Exception('Respuesta no JSON: ${response.body}');
          }
        } else {
          throw Exception('Respuesta no JSON: ${response.body}');
        }
      }

      if (jsonResponse is List) {
        return jsonResponse.map((e) {
          if (e is Map<String, dynamic>) return SpotifyTrack.fromJson(e);
          return SpotifyTrack.fromJson(Map<String, dynamic>.from(e));
        }).toList();
      }

      if (jsonResponse is Map<String, dynamic>) {
        final candidates = ['results', 'tracks', 'data', 'items', 'songs'];
        for (final key in candidates) {
          if (jsonResponse.containsKey(key)) {
            final node = jsonResponse[key];
            if (node is List) {
              return node.map((e) {
                if (e is Map<String, dynamic>) return SpotifyTrack.fromJson(e);
                return SpotifyTrack.fromJson(Map<String, dynamic>.from(e));
              }).toList();
            }
          }
        }

        for (final entry in jsonResponse.entries) {
          if (entry.value is List) {
            final list = entry.value as List;
            return list.map((e) {
              if (e is Map<String, dynamic>) return SpotifyTrack.fromJson(e);
              return SpotifyTrack.fromJson(Map<String, dynamic>.from(e));
            }).toList();
          }
        }
      }

      throw Exception('Formato de respuesta inesperado');
    } catch (e, st) {
      print('[SpotifyService] searchSongs error: $e');
      print(st);
      rethrow;
    }
  }

  /// Get download URL for a Spotify track
  /// Intenta primero con Dorratz API, si falla usa RapidAPI
  Future<DownloadInfo> getDownloadUrl(
    String spotifyUrl, {
    String? trackName,
    String? artistName,
    String? imageUrl,
  }) async {
    print(
      '[SpotifyService] 🔄 Iniciando búsqueda de descarga para: $spotifyUrl',
    );

    // Verificar si la canción requiere bypass de APIs de Spotify (ej. caché corrupto)
    if (_shouldBypassSpotifyApis(trackName, artistName)) {
      print(
        '[SpotifyService] ⚠️ Track en lista de bypass: forzando fallback a YouTube/Foranly',
      );
      throw Exception('Track bypassing Spotify APIs (Cache issues)');
    }

    // Intentar primero con la API de Dorratz
    try {
      print('[SpotifyService] Intentando Dorratz API...');
      final url = Uri.parse(ApiConfig.getSpotifyDownloadUrl(spotifyUrl));

      final response = await http.get(url).timeout(const Duration(seconds: 15));
      print('[SpotifyService] Dorratz status=${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);

        // Verificar si hay error en la respuesta
        if (jsonResponse is Map<String, dynamic>) {
          if (jsonResponse.containsKey('error')) {
            print(
              '[SpotifyService] Dorratz devolvió error: ${jsonResponse['error']}',
            );
            throw Exception('Dorratz API error: ${jsonResponse['error']}');
          }

          final downloadInfo = DownloadInfo.fromJson(jsonResponse);

          // Verificar que la URL no esté vacía
          if (downloadInfo.downloadUrl.isEmpty) {
            throw Exception('Dorratz devolvió URL vacía');
          }

          print('[SpotifyService] ✓ Dorratz API exitosa');
          print('✅ [API SUCCESS] Usando API: Dorratz (Spotify)');
          return downloadInfo;
        }
      }

      throw Exception('Dorratz API falló con status: ${response.statusCode}');
    } catch (e) {
      print('[SpotifyService] Dorratz falló: $e');
      print('[SpotifyService] Intentando FabDL como fallback secundario...');

      // Fallback 2: intentar FabDL
      try {
        return await _getDownloadUrlFromFabDL(
          spotifyUrl,
          trackName: trackName,
          artistName: artistName,
          imageUrl: imageUrl,
        );
      } catch (fabdlError) {
        print('[SpotifyService] FabDL falló: $fabdlError');
        print('[SpotifyService] Intentando RapidAPI como último fallback...');

        // Fallback 3: usar RapidAPI
        return await _getDownloadUrlFromRapidApi(
          spotifyUrl,
          trackName: trackName,
          artistName: artistName,
          imageUrl: imageUrl,
        );
      }
    }
  }

  /// Obtener URL de descarga usando FabDL API
  Future<DownloadInfo> _getDownloadUrlFromFabDL(
    String spotifyUrl, {
    String? trackName,
    String? artistName,
    String? imageUrl,
  }) async {
    try {
      print('[SpotifyService] Llamando FabDL API...');

      // Primera llamada: obtener metadata
      final encodedUrl = Uri.encodeComponent(spotifyUrl);
      final metadataUrl = Uri.parse(
        'https://api.fabdl.com/spotify/get?url=$encodedUrl',
      );

      final metadataResponse = await http
          .get(
            metadataUrl,
            headers: {'accept': 'application/json, text/plain, */*'},
          )
          .timeout(const Duration(seconds: 15));

      print(
        '[SpotifyService] FabDL metadata status=${metadataResponse.statusCode}',
      );

      if (metadataResponse.statusCode != 200) {
        throw Exception('FabDL metadata error: ${metadataResponse.statusCode}');
      }

      final metadataJson = json.decode(metadataResponse.body);

      // Log completo del metadata response
      print(
        '[SpotifyService] FabDL metadata response: ${metadataResponse.body}',
      );

      if (metadataJson['result'] == null) {
        throw Exception('FabDL no devolvió result');
      }

      final result = metadataJson['result'];
      final gid = result['gid'];
      final id = result['id'];

      if (gid == null || id == null) {
        throw Exception('FabDL no devolvió gid o id');
      }

      print('[SpotifyService] FabDL gid=$gid, id=$id');

      // Segunda llamada: obtener URL de descarga
      final downloadUrl = Uri.parse(
        'https://api.fabdl.com/spotify/mp3-convert-task/$gid/$id',
      );

      final downloadResponse = await http
          .get(
            downloadUrl,
            headers: {'accept': 'application/json, text/plain, */*'},
          )
          .timeout(const Duration(seconds: 20));

      print(
        '[SpotifyService] FabDL download status=${downloadResponse.statusCode}',
      );

      if (downloadResponse.statusCode != 200) {
        throw Exception('FabDL download error: ${downloadResponse.statusCode}');
      }

      final downloadJson = json.decode(downloadResponse.body);

      print(
        '[SpotifyService] FabDL download response: ${downloadResponse.body}',
      );

      if (downloadJson['result'] == null) {
        throw Exception('FabDL no devolvió result en download response');
      }

      final downloadResult = downloadJson['result'];

      // Verificar el estado de la conversión
      final status = downloadResult['status'];
      if (status != null && (status == -2 || status == -3)) {
        throw Exception(
          'FabDL conversión falló (status: $status, track no disponible)',
        );
      }

      // FabDL devuelve un 'tid' (task ID) en lugar de download_url directamente
      final tid = downloadResult['tid'];

      if (tid == null || tid.toString().isEmpty) {
        throw Exception('FabDL no devolvió tid (task ID)');
      }

      // Construir la URL de descarga usando el tid
      final finalDownloadUrl =
          'https://api.fabdl.com/spotify/download-mp3/$tid';

      print('[SpotifyService] FabDL tid=$tid');
      print(
        '[SpotifyService] FabDL download URL construida: $finalDownloadUrl',
      );

      // Construir DownloadInfo
      final downloadInfo = DownloadInfo(
        name: result['name'] ?? trackName ?? 'Unknown Track',
        artists: result['artists'] ?? artistName ?? 'Unknown Artist',
        imageUrl: result['image'] ?? imageUrl ?? '',
        downloadUrl: finalDownloadUrl,
        durationMs: result['duration_ms'] ?? 0,
      );

      print('[SpotifyService] ✓ FabDL API exitosa');
      print('✅ [API SUCCESS] Usando API: FabDL (Spotify Direct)');
      print('[SpotifyService]   Track: ${downloadInfo.name}');
      print('[SpotifyService]   Artist: ${downloadInfo.artists}');
      print('[SpotifyService]   Duration: ${downloadInfo.durationMs}ms');

      return downloadInfo;
    } catch (e) {
      print('[SpotifyService] FabDL falló completamente: $e');
      rethrow;
    }
  }

  /// Obtener URL de descarga usando RapidAPI Spotify Downloader
  Future<DownloadInfo> _getDownloadUrlFromRapidApi(
    String spotifyUrl, {
    String? trackName,
    String? artistName,
    String? imageUrl,
  }) async {
    try {
      final encodedUrl = Uri.encodeComponent(spotifyUrl);
      final url = Uri.parse(
        '${ApiConfig.rapidApiSpotifyDownloader}?songId=$encodedUrl',
      );

      print('[SpotifyService] Llamando RapidAPI...');

      final response = await http
          .get(
            url,
            headers: {
              'x-rapidapi-key': _rapidApiKey,
              'x-rapidapi-host': 'spotify-downloader9.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 20));

      print('[SpotifyService] RapidAPI status=${response.statusCode}');
      print('[SpotifyService] RapidAPI body=${response.body}');

      if (response.statusCode != 200) {
        throw Exception('RapidAPI error: ${response.statusCode}');
      }

      final jsonResponse = json.decode(response.body);

      if (jsonResponse['success'] != true) {
        throw Exception('RapidAPI devolvió success=false');
      }

      final data = jsonResponse['data'];
      if (data == null) {
        throw Exception('RapidAPI no devolvió data');
      }

      // Construir DownloadInfo desde la respuesta de RapidAPI
      final downloadInfo = DownloadInfo(
        name: data['title'] ?? '',
        artists: data['artist'] ?? '',
        imageUrl: data['cover'] ?? '',
        downloadUrl: data['downloadLink'] ?? '',
        durationMs: 0, // RapidAPI no devuelve duración
      );

      if (downloadInfo.downloadUrl.isEmpty) {
        throw Exception('RapidAPI devolvió downloadLink vacío');
      }

      print('[SpotifyService] ✓ RapidAPI exitosa');
      print('✅ [API SUCCESS] Usando API: RapidAPI Spotify Downloader');
      print('[SpotifyService]   Track: ${downloadInfo.name}');
      print('[SpotifyService]   Artist: ${downloadInfo.artists}');

      return downloadInfo;
    } catch (e) {
      print('[SpotifyService] RapidAPI principal falló: $e');
      print('[SpotifyService] Intentando RapidAPI Backup...');
      return await _getDownloadUrlFromRapidApiBackup(
        spotifyUrl,
        trackName: trackName,
        artistName: artistName,
        imageUrl: imageUrl,
      );
    }
  }

  /// Extraer información de track desde un SpotifyTrack para YouTube fallback
  /// Esto asegura que siempre tengamos información para buscar en YouTube

  /// Obtener URL de descarga usando la API alternativa "Spotify Music MP3 Downloader" (Backup)
  Future<DownloadInfo> _getDownloadUrlFromRapidApiBackup(
    String spotifyUrl, {
    String? trackName,
    String? artistName,
    String? imageUrl,
  }) async {
    try {
      print(
        '[SpotifyService] Intentando RapidAPI Backup (Spotify Music MP3)...',
      );

      final response = await http
          .get(
            Uri.parse('${ApiConfig.rapidApiSpotifyMusicMp3}?link=$spotifyUrl'),
            headers: {
              'x-rapidapi-key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
              'x-rapidapi-host':
                  'spotify-music-mp3-downloader-api.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 20));

      print('[SpotifyService] RapidAPI Backup status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);

        print(
          '[SpotifyService] RapidAPI Backup JSON preview: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}...',
        );

        String? downloadUrl;
        String title = trackName ?? 'Spotify Track';
        String artist = artistName ?? 'Unknown Artist';
        String thumbnail = imageUrl ?? '';

        // La estructura puede ser { data: { medias: [...] } } o directa
        final data = jsonResponse['data'] ?? jsonResponse;

        if (data['medias'] != null &&
            data['medias'] is List &&
            (data['medias'] as List).isNotEmpty) {
          final firstMedia = data['medias'][0];
          if (firstMedia['url'] != null) {
            downloadUrl = firstMedia['url'];
            print('[SpotifyService] ✓ URL encontrada en medias[0].url');
          }
        } else if (data['link'] != null) {
          downloadUrl = data['link'];
        } else if (data['download_link'] != null) {
          downloadUrl = data['download_link'];
        } else if (data['url'] != null) {
          downloadUrl = data['url'];
        }

        // Solo sobrescribir metadata si no la tenemos
        if (trackName == null && data['title'] != null) title = data['title'];
        if (artistName == null && data['author'] != null)
          artist = data['author'];
        if (artistName == null && data['artist'] != null)
          artist = data['artist'];
        if (imageUrl == null && data['thumbnail'] != null)
          thumbnail = data['thumbnail'];

        if (downloadUrl != null && downloadUrl.isNotEmpty) {
          print('[SpotifyService] ✓ RapidAPI Backup exitosa');
          print('✅ [API SUCCESS] Usando API: RapidAPI Spotify Backup');
          return DownloadInfo(
            downloadUrl: downloadUrl,
            name: title,
            artists: artist,
            imageUrl: thumbnail,
            durationMs: 0,
          );
        }
      }
      throw Exception('RapidAPI Backup falló o estructura desconocida');
    } catch (e) {
      print('[SpotifyService] RapidAPI Backup falló: $e');
      // Spotify 246 desactivada por ahora
      // print('[SpotifyService] Intentando Spotify 246 API (Stream Directo)...');
      // return await _downloadFromSpotify246(
      //   spotifyUrl,
      //   trackName: trackName,
      //   artistName: artistName,
      //   imageUrl: imageUrl,
      // );
      throw e;
    }
  }

  /// Descarga directa desde Spotify 246 API (Option 4)
  /// Devuelve URL local (file://...)
  Future<DownloadInfo> _downloadFromSpotify246(
    String spotifyUrl, {
    String? trackName,
    String? artistName,
    String? imageUrl,
  }) async {
    try {
      print('[SpotifyService] Intentando Spotify 246 API (Direct Stream)...');

      // Extraer ID de Spotify de manera robusta
      // Formatos: https://open.spotify.com/track/ID o spotify:track:ID
      String? trackId;

      if (spotifyUrl.contains('/track/')) {
        final uri = Uri.parse(spotifyUrl);
        if (uri.pathSegments.isNotEmpty && uri.pathSegments.contains('track')) {
          final index = uri.pathSegments.indexOf('track');
          if (index + 1 < uri.pathSegments.length) {
            trackId = uri.pathSegments[index + 1];
          }
        }
      } else if (spotifyUrl.startsWith('spotify:track:')) {
        trackId = spotifyUrl.split(':').last;
      }

      if (trackId == null) {
        throw Exception('No se pudo extraer el ID de la canción de Spotify');
      }

      print('[SpotifyService] Track ID extraído: $trackId');

      final response = await http
          .get(
            Uri.parse('${ApiConfig.rapidApiSpotify246}?id=$trackId'),
            headers: {
              'x-rapidapi-key': _rapidApiKey,
              'x-rapidapi-host': 'spotify246.p.rapidapi.com',
            },
          )
          .timeout(const Duration(seconds: 45));

      print('[SpotifyService] Spotify 246 status: ${response.statusCode}');

      if (response.statusCode == 200 || response.statusCode == 206) {
        // Guardar bytes en archivo temporal
        final tempDir = await getTemporaryDirectory();
        final fileName =
            'spotify_246_${DateTime.now().millisecondsSinceEpoch}.mp3';
        final file = File('${tempDir.path}/$fileName');

        await file.writeAsBytes(response.bodyBytes);
        print('[SpotifyService] Archivo guardado localmente: ${file.path}');
        print('✅ [API SUCCESS] Usando API: Spotify 246 (Direct Stream)');

        // Usar los metadatos proporcionados o valores genéricos si no hay
        return DownloadInfo(
          downloadUrl:
              'file://${file.path}', // Prefijo file:// para que DownloadService sepa que es local
          name: trackName ?? 'Spotify Track',
          artists: artistName ?? 'Spotify Artist',
          imageUrl:
              imageUrl ??
              'https://placehold.co/600x600/1db954/ffffff?text=Spotify',
          durationMs: 0,
        );
      }

      throw Exception('Spotify 246 falló con status ${response.statusCode}');
    } catch (e) {
      print('[SpotifyService] Spotify 246 falló: $e');
      throw e; // Aquí ya dejamos que falle y active el YouTube Fallback
    }
  }

  Map<String, String> extractTrackInfo(SpotifyTrack track) {
    String trackName = track.title.trim();
    String artistName = track.artists.trim();

    // Si no hay artista en el track, intentamos extraerlo del título
    if (artistName.isEmpty && trackName.contains(' - ')) {
      final parts = trackName.split(' - ');
      if (parts.length >= 2) {
        artistName = parts[0].trim();
        trackName = parts.sublist(1).join(' - ').trim();
      }
    }

    return {'trackName': trackName, 'artistName': artistName};
  }

  /// Verifica si una canción debe saltarse las APIs de descarga directa de Spotify
  /// y pasar directamente al fallback de YouTube (que usa Foranly).
  /// Útil para canciones donde las APIs de Spotify devuelven audio incorrecto (caché corrupto).
  bool _shouldBypassSpotifyApis(String? trackName, String? artistName) {
    if (trackName == null || artistName == null) return false;

    final t = trackName.toLowerCase();
    final a = artistName.toLowerCase();

    // Bad Bunny
    if (a.contains('bad bunny')) {
      // Casos específicos reportados
      if (t.contains('un preview')) return true;
      if (t.contains('kloufrens') || t.contains('close friends')) return true;
    }

    return false;
  }
}
