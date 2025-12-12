import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/spotify_track.dart';
import '../models/download_info.dart';

class SpotifyService {
  static const String _searchBaseUrl = 'https://api.dorratz.com/spotifysearch';
  static const String _downloadBaseUrl = 'https://api.dorratz.com/spotifydl';

  // RapidAPI Spotify Downloader (API de respaldo)
  static const String _rapidApiUrl =
      'https://spotify-downloader9.p.rapidapi.com/downloadSong';
  static const String _rapidApiKey =
      '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0';
  static const String _rapidApiHost = 'spotify-downloader9.p.rapidapi.com';

  /// Search for songs on Spotify (robust parsing + logs)
  Future<List<SpotifyTrack>> searchSongs(String query) async {
    final encodedQuery = Uri.encodeComponent(query);
    final url = Uri.parse('$_searchBaseUrl?query=$encodedQuery');

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

    // Intentar primero con la API de Dorratz
    try {
      print('[SpotifyService] Intentando Dorratz API...');
      final encodedUrl = Uri.encodeComponent(spotifyUrl);
      final url = Uri.parse('$_downloadBaseUrl?url=$encodedUrl');

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
      print('[SpotifyService] Intentando RapidAPI como fallback...');

      // Fallback: usar RapidAPI Spotify Downloader
      return await _getDownloadUrlFromRapidApi(
        spotifyUrl,
        trackName: trackName,
        artistName: artistName,
        imageUrl: imageUrl,
      );
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
      final url = Uri.parse('$_rapidApiUrl?songId=$encodedUrl');

      print('[SpotifyService] Llamando RapidAPI...');

      final response = await http
          .get(
            url,
            headers: {
              'x-rapidapi-key': _rapidApiKey,
              'x-rapidapi-host': _rapidApiHost,
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
            Uri.parse(
              'https://spotify-music-mp3-downloader-api.p.rapidapi.com/download?link=$spotifyUrl',
            ),
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
            Uri.parse('https://spotify246.p.rapidapi.com/audio?id=$trackId'),
            headers: {
              'x-rapidapi-key':
                  '60483ce3d8msh0dd02224b6be809p1de00cjsn4242ca1ee9c0',
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
}
