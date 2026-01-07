import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import '../services/playlist_service.dart';
import '../services/music_library_service.dart';
import '../models/song.dart';

class GroqAssistantService {
  // Usar configuración centralizada
  static String get _apiUrl => ApiConfig.groqEndpoint;
  static String get _apiKey => ApiConfig.groqApiKey;
  static String get _model => ApiConfig.groqModel;

  final List<Map<String, String>> _conversationHistory = [];
  List<Song> _availableSongs = [];
  bool _songsLoaded = false;

  /// Cargar canciones desde la carpeta seleccionada
  Future<void> _loadSongsIfNeeded() async {
    print('[GroqAssistant] === LOADING SONGS ===');
    print('[GroqAssistant] _songsLoaded: $_songsLoaded');
    print('[GroqAssistant] Current songs count: ${_availableSongs.length}');

    if (_songsLoaded) {
      print('[GroqAssistant] Songs already loaded, skipping');
      return;
    }

    try {
      print('[GroqAssistant] Getting SharedPreferences...');
      final prefs = await SharedPreferences.getInstance();
      final selectedFolder = prefs.getString(
        'last_music_folder',
      ); // Usar la misma key que LocalMusicScreen

      print('[GroqAssistant] Selected folder: $selectedFolder');

      if (selectedFolder != null && selectedFolder.isNotEmpty) {
        print('[GroqAssistant] Loading songs from: $selectedFolder');
        _availableSongs = await MusicLibraryService.scanFolder(selectedFolder);
        _songsLoaded = true;
        print(
          '[GroqAssistant] ✓ Successfully loaded ${_availableSongs.length} songs',
        );

        // Log first 3 songs as sample
        if (_availableSongs.isNotEmpty) {
          print('[GroqAssistant] Sample songs:');
          for (var i = 0; i < _availableSongs.length && i < 3; i++) {
            print(
              '[GroqAssistant]   - ${_availableSongs[i].title} by ${_availableSongs[i].artist}',
            );
          }
        }
      } else {
        print(
          '[GroqAssistant] ✗ No music folder selected in SharedPreferences',
        );
      }
    } catch (e, stackTrace) {
      print('[GroqAssistant] ✗ Error loading songs: $e');
      print('[GroqAssistant] Stack trace: $stackTrace');
    }

    print('[GroqAssistant] === END LOADING SONGS ===');
  }

  /// Enviar mensaje al asistente
  Future<String> sendMessage(String userMessage) async {
    try {
      // Cargar canciones si no están cargadas
      await _loadSongsIfNeeded();

      // Agregar mensaje del usuario al historial
      _conversationHistory.add({'role': 'user', 'content': userMessage});

      // Obtener contexto de música
      final musicContext = _getMusicContext();

      // Preparar mensajes para la API
      final messages = [
        {
          'role': 'system',
          'content':
              '''Eres un asistente musical inteligente integrado en una app de música.

BIBLIOTECA DISPONIBLE:
$musicContext

PLAYLISTS EXISTENTES:
${_getPlaylistContext()}

CAPACIDADES:
1. Crear playlists nuevas con canciones de la biblioteca
2. Actualizar playlists existentes agregando canciones
3. Renombrar playlists existentes
4. Editar descripción de playlists
5. Eliminar playlists
6. Eliminar canciones de playlists
7. Recomendar música basada en mood/género
8. Buscar canciones específicas

REGLAS CRÍTICAS:
- Para ACCIONES DE PLAYLIST: Responde SOLO el JSON (o múltiples JSONs), sin texto adicional
- Si el usuario pide MÚLTIPLES acciones, devuelve MÚLTIPLES JSONs (uno por línea)
- Para CONVERSACIÓN: Responde SOLO texto natural, sin JSON
- NO mezcles JSON con explicaciones
- Cuando el usuario mencione una playlist, usa el nombre EXACTO de las playlists existentes
- Identifica correctamente la acción que el usuario quiere realizar

PALABRAS CLAVE POR ACCIÓN:
- "crea", "nueva" → create_playlist
- "agrega", "añade", "pon" (canciones) → update_playlist
- "cambia el nombre", "renombra" → rename_playlist
- "cambia/edita la descripción" → edit_description
- "elimina/borra la playlist" → delete_playlist
- "quita/elimina/borra" (canción de playlist) → remove_song

IMPORTANTE PARA BÚSQUEDA DE CANCIONES:
- Si el usuario dice "canciones de [artista]", usa "artist:[nombre_artista]" en el array de songs
- Si el usuario dice el nombre de una canción específica, usa el título directamente
- Ejemplos:
  * "agrega canciones de Bad Bunny" → songs: ["artist:Bad Bunny"]
  * "agrega Tarot y Monaco" → songs: ["Tarot", "Monaco"]
  * "agrega todas las de Bad Bunny" → songs: ["artist:Bad Bunny"]

FORMATOS JSON:

CREATE PLAYLIST:
{
  "action": "create_playlist",
  "name": "Nombre de la Playlist",
  "description": "Descripción breve",
  "songs": ["Canción 1", "Canción 2"]
}

UPDATE PLAYLIST (agregar canciones):
{
  "action": "update_playlist",
  "name": "Nombre de la Playlist",
  "songs": ["Canción 1", "Canción 2"]
}

RENAME PLAYLIST:
{
  "action": "rename_playlist",
  "old_name": "Nombre Actual",
  "new_name": "Nuevo Nombre"
}

EDIT DESCRIPTION:
{
  "action": "edit_description",
  "name": "Nombre de la Playlist",
  "description": "Nueva descripción"
}

DELETE PLAYLIST:
{
  "action": "delete_playlist",
  "name": "Nombre de la Playlist"
}

REMOVE SONG:
{
  "action": "remove_song",
  "playlist_name": "Nombre de la Playlist",
  "song": "Nombre de la Canción"
}

IMPORTANTE:
- Usa nombres EXACTOS de playlists y canciones
- Si el usuario no especifica algo necesario, pregunta
- Si no entiendes, pregunta en lugar de adivinar

Ejemplos:
Usuario: "Crea una playlist de reggaeton"
Tú: {"action": "create_playlist", "name": "Reggaeton Mix", "description": "Lo mejor del reggaeton", "songs": ["Tarot", "Monaco"]}

Usuario: "Agrega más canciones a Lo que es"
Tú: {"action": "update_playlist", "name": "Lo que es", "songs": ["Caile", "DAKITI"]}

Usuario: "Renombra sf a Favoritas"
Tú: {"action": "rename_playlist", "old_name": "sf", "new_name": "Favoritas"}

Usuario: "Cambia la descripción de Favoritas a 'Mis canciones preferidas'"
Tú: {"action": "edit_description", "name": "Favoritas", "description": "Mis canciones preferidas"}

Usuario: "Elimina la playlist sf"
Tú: {"action": "delete_playlist", "name": "sf"}

Usuario: "Quita Tarot de la playlist Favoritas"
Tú: {"action": "remove_song", "playlist_name": "Favoritas", "song": "Tarot"}

Usuario: "Renombra la playlist A a X y la playlist B a Y"
Tú: {"action": "rename_playlist", "old_name": "A", "new_name": "X"}
{"action": "rename_playlist", "old_name": "B", "new_name": "Y"}

Usuario: "Agrega canciones de Bad Bunny a Favoritas"
Tú: {"action": "update_playlist", "name": "Favoritas", "songs": ["artist:Bad Bunny"]}

Usuario: "Crea una playlist con todas las canciones de Young Cister"
Tú: {"action": "create_playlist", "name": "Young Cister Mix", "description": "Canciones de Young Cister", "songs": ["artist:Young Cister"]}

Usuario: "¿Qué canciones de Bad Bunny tengo?"
Tú: Tienes varias canciones de Bad Bunny en tu biblioteca, como "Tarot", "Monaco", etc.''',
        },
        ..._conversationHistory,
      ];

      // Llamar a la API de Groq
      final response = await http
          .post(
            Uri.parse(_apiUrl),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': _model,
              'messages': messages,
              'temperature': 0.7,
              'max_tokens': 800,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final assistantMessage =
            data['choices'][0]['message']['content'] as String;

        // Agregar respuesta al historial
        _conversationHistory.add({
          'role': 'assistant',
          'content': assistantMessage,
        });

        // Procesar acciones (crear/actualizar playlist) y obtener mensaje de confirmación
        final actionResult = await _processAction(assistantMessage);

        // Si hubo una acción procesada, devolver el mensaje de confirmación
        // Si no, devolver el mensaje original del asistente
        return actionResult ?? assistantMessage;
      } else {
        print(
          '[GroqAssistant] Error: ${response.statusCode} - ${response.body}',
        );
        return 'Lo siento, hubo un error al procesar tu solicitud. Intenta de nuevo.';
      }
    } catch (e) {
      print('[GroqAssistant] Exception: $e');
      return 'Error de conexión. Verifica tu internet e intenta nuevamente.';
    }
  }

  /// Obtener contexto de música para el prompt
  String _getMusicContext() {
    print('[GroqAssistant] === GETTING MUSIC CONTEXT ===');
    print('[GroqAssistant] Available songs count: ${_availableSongs.length}');

    if (_availableSongs.isEmpty) {
      final message =
          'No hay canciones disponibles. Pídele al usuario que vaya a "Local Music" primero.';
      print('[GroqAssistant] ✗ $message');
      return message;
    }

    // Limitar a 30 canciones para no saturar el prompt
    final limitedSongs = _availableSongs.take(30).toList();
    final songList = limitedSongs
        .map((s) => '- "${s.title}" por ${s.artist}')
        .join('\n');

    final context =
        '''
Total de canciones: ${_availableSongs.length}
Canciones (mostrando ${limitedSongs.length}):
$songList
''';

    print(
      '[GroqAssistant] ✓ Generated context with ${limitedSongs.length} songs',
    );
    return context;
  }

  /// Obtener contexto de playlists existentes
  String _getPlaylistContext() {
    try {
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No hay playlists creadas aún.';
      }

      final playlistList = playlists
          .take(10) // Limitar a 10 playlists
          .map((p) => '- "${p.name}" (${p.songs.length} canciones)')
          .join('\n');

      return '''
Total de playlists: ${playlists.length}
Playlists (mostrando ${playlists.take(10).length}):
$playlistList
''';
    } catch (e) {
      print('[GroqAssistant] Error getting playlist context: $e');
      return 'No se pudieron cargar las playlists.';
    }
  }

  /// Procesar acciones del asistente
  Future<String?> _processAction(String message) async {
    try {
      print('[GroqAssistant] === PROCESSING ACTION ===');

      // Buscar TODOS los JSONs en el mensaje (no solo el primero)
      final jsonMatches = RegExp(r'\{[\s\S]*?\}').allMatches(message);

      if (jsonMatches.isEmpty) {
        print('[GroqAssistant] No JSON action found');
        return null;
      }

      final results = <String>[];

      // Procesar cada JSON encontrado
      for (final match in jsonMatches) {
        final jsonStr = match.group(0)!;
        print(
          '[GroqAssistant] Found JSON: ${jsonStr.substring(0, jsonStr.length > 100 ? 100 : jsonStr.length)}...',
        );

        try {
          final action = jsonDecode(jsonStr);
          final actionType = action['action'];
          print('[GroqAssistant] ✓ Parsed action: $actionType');

          String? result;

          if (actionType == 'create_playlist') {
            print('[GroqAssistant] Creating playlist: ${action['name']}');
            result = await _createPlaylist(
              action['name'] as String,
              action['description'] as String?,
              (action['songs'] as List<dynamic>?)?.cast<String>(),
            );
          } else if (actionType == 'update_playlist') {
            print('[GroqAssistant] Updating playlist: ${action['name']}');
            result = await _updatePlaylist(
              action['name'] as String,
              (action['songs'] as List<dynamic>?)?.cast<String>(),
            );
          } else if (actionType == 'rename_playlist') {
            print(
              '[GroqAssistant] Renaming playlist: ${action['old_name']} -> ${action['new_name']}',
            );
            result = await _renamePlaylist(
              action['old_name'] as String,
              action['new_name'] as String,
            );
          } else if (actionType == 'edit_description') {
            print('[GroqAssistant] Editing description: ${action['name']}');
            result = await _editDescription(
              action['name'] as String,
              action['description'] as String,
            );
          } else if (actionType == 'delete_playlist') {
            print('[GroqAssistant] Deleting playlist: ${action['name']}');
            result = await _deletePlaylist(action['name'] as String);
          } else if (actionType == 'remove_song') {
            print(
              '[GroqAssistant] Removing song: ${action['song']} from ${action['playlist_name']}',
            );
            result = await _removeSong(
              action['playlist_name'] as String,
              action['song'] as String,
            );
          }

          if (result != null) {
            results.add(result);
          }
        } catch (parseError) {
          print('[GroqAssistant] ✗ JSON parse error: $parseError');
        }
      }

      // Si se procesaron múltiples acciones, combinar los resultados
      if (results.isEmpty) {
        return null;
      } else if (results.length == 1) {
        return results.first;
      } else {
        // Múltiples acciones: combinar mensajes
        return results.join('\n');
      }
    } catch (e) {
      print('[GroqAssistant] ✗ Error processing action: $e');
      return null;
    }
  }

  /// Crear playlist con canciones de la biblioteca
  Future<String> _createPlaylist(
    String name,
    String? description,
    List<String>? songTitles,
  ) async {
    try {
      final selectedSongs = <Song>[];
      final notFound = <String>[];

      if (songTitles != null && songTitles.isNotEmpty) {
        // Buscar canciones por título o artista
        for (final query in songTitles) {
          if (query.startsWith('artist:')) {
            // Búsqueda por artista
            final artistName = query.substring(7).toLowerCase().trim();
            final artistSongs = _availableSongs
                .where(
                  (s) =>
                      s.artist.toLowerCase().contains(artistName) ||
                      artistName.contains(s.artist.toLowerCase()),
                )
                .toList();

            if (artistSongs.isNotEmpty) {
              selectedSongs.addAll(artistSongs);
            } else {
              notFound.add('artista "$artistName"');
            }
          } else {
            // Búsqueda por título
            final song = _availableSongs.firstWhere(
              (s) =>
                  s.title.toLowerCase().contains(query.toLowerCase()) ||
                  query.toLowerCase().contains(s.title.toLowerCase()),
              orElse: () => Song(id: '', title: '', artist: '', filePath: ''),
            );

            if (song.id.isNotEmpty) {
              selectedSongs.add(song);
            } else {
              notFound.add('"$query"');
            }
          }
        }
      }

      if (selectedSongs.isEmpty) {
        if (notFound.isNotEmpty) {
          return 'No encontré: ${notFound.join(", ")}. Verifica los nombres en tu biblioteca.';
        }
        print('[GroqAssistant] No songs found for playlist');
        return 'No pude encontrar canciones para la playlist. Intenta con otros nombres.';
      }

      // Crear playlist usando PlaylistService
      final playlist = await PlaylistService().createPlaylist(
        name,
        description: description,
      );

      // Agregar canciones a la playlist
      for (final song in selectedSongs) {
        await PlaylistService().addSongToPlaylist(playlist.id, song);
      }

      print(
        '[GroqAssistant] ✓ Playlist "$name" created with ${selectedSongs.length} songs',
      );

      // Mensaje detallado
      final songNames = selectedSongs
          .take(5)
          .map((s) => '"${s.title}"')
          .join(', ');
      final moreText = selectedSongs.length > 5
          ? ' y ${selectedSongs.length - 5} más'
          : '';

      String message =
          '✓ Playlist "$name" creada con ${selectedSongs.length} canciones: $songNames$moreText.';

      if (notFound.isNotEmpty) {
        message += '\n\n⚠️ No encontré: ${notFound.join(", ")}.';
      }

      return message;
    } catch (e) {
      print('[GroqAssistant] Error creating playlist: $e');
      return 'Hubo un error al crear la playlist. Intenta de nuevo.';
    }
  }

  /// Actualizar playlist existente con nuevas canciones
  Future<String> _updatePlaylist(String name, List<String>? songTitles) async {
    try {
      // Normalizar el nombre de búsqueda
      final searchName = name.toLowerCase().trim();

      // Buscar playlist por nombre
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No tienes playlists creadas aún. ¿Quieres que cree una?';
      }

      // Buscar con múltiples estrategias
      var playlist = playlists.firstWhere(
        (p) => p.name.toLowerCase().trim() == searchName,
        orElse: () => playlists.firstWhere(
          (p) =>
              p.name.toLowerCase().contains(searchName) ||
              searchName.contains(p.name.toLowerCase()),
          orElse: () => throw Exception('Playlist no encontrada'),
        ),
      );

      if (songTitles == null || songTitles.isEmpty) {
        return 'No especificaste qué canciones agregar a "${playlist.name}".';
      }

      final selectedSongs = <Song>[];
      final notFound = <String>[];

      // Buscar canciones por título o artista
      for (final query in songTitles) {
        if (query.startsWith('artist:')) {
          // Búsqueda por artista
          final artistName = query.substring(7).toLowerCase().trim();
          final artistSongs = _availableSongs
              .where(
                (s) =>
                    s.artist.toLowerCase().contains(artistName) ||
                    artistName.contains(s.artist.toLowerCase()),
              )
              .toList();

          if (artistSongs.isNotEmpty) {
            selectedSongs.addAll(artistSongs);
          } else {
            notFound.add('artista "$artistName"');
          }
        } else {
          // Búsqueda por título
          final song = _availableSongs.firstWhere(
            (s) =>
                s.title.toLowerCase().contains(query.toLowerCase()) ||
                query.toLowerCase().contains(s.title.toLowerCase()),
            orElse: () => Song(id: '', title: '', artist: '', filePath: ''),
          );

          if (song.id.isNotEmpty) {
            selectedSongs.add(song);
          } else {
            notFound.add('"$query"');
          }
        }
      }

      if (selectedSongs.isEmpty) {
        if (notFound.isNotEmpty) {
          return 'No encontré: ${notFound.join(", ")}. Verifica los nombres en tu biblioteca.';
        }
        return 'No pude encontrar las canciones que mencionaste.';
      }

      // Agregar canciones a la playlist
      int addedCount = 0;
      for (final song in selectedSongs) {
        await PlaylistService().addSongToPlaylist(playlist.id, song);
        addedCount++;
      }

      print(
        '[GroqAssistant] ✓ Playlist "${playlist.name}" updated with $addedCount songs',
      );

      // Mensaje detallado
      final songNames = selectedSongs
          .take(5)
          .map((s) => '"${s.title}"')
          .join(', ');
      final moreText = selectedSongs.length > 5
          ? ' y ${selectedSongs.length - 5} más'
          : '';

      String message =
          '✓ Agregué $addedCount canciones a "${playlist.name}": $songNames$moreText.';

      if (notFound.isNotEmpty) {
        message += '\n\n⚠️ No encontré: ${notFound.join(", ")}.';
      }

      return message;
    } catch (e) {
      print('[GroqAssistant] Error updating playlist: $e');

      // Listar playlists disponibles
      final playlists = PlaylistService().playlists;
      if (playlists.isNotEmpty) {
        final names = playlists.take(5).map((p) => '"${p.name}"').join(', ');
        return 'No encontré la playlist "$name". Tienes: $names. ¿Cuál quieres actualizar?';
      }

      return 'No pude encontrar la playlist "$name". ¿Quieres que la cree?';
    }
  }

  /// Renombrar playlist existente
  Future<String> _renamePlaylist(String oldName, String newName) async {
    try {
      // Normalizar nombres
      final searchName = oldName.toLowerCase().trim();

      // Buscar playlist
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No tienes playlists creadas aún.';
      }

      // Buscar con múltiples estrategias
      var playlist = playlists.firstWhere(
        (p) => p.name.toLowerCase().trim() == searchName,
        orElse: () => playlists.firstWhere(
          (p) =>
              p.name.toLowerCase().contains(searchName) ||
              searchName.contains(p.name.toLowerCase()),
          orElse: () => throw Exception('Playlist no encontrada'),
        ),
      );

      // Renombrar usando PlaylistService.updatePlaylist
      await PlaylistService().updatePlaylist(playlist.id, name: newName);

      print(
        '[GroqAssistant] ✓ Playlist renamed from "${playlist.name}" to "$newName"',
      );

      return '✓ Renombré la playlist de "${playlist.name}" a "$newName".';
    } catch (e) {
      print('[GroqAssistant] Error renaming playlist: $e');

      // Listar playlists disponibles
      final playlists = PlaylistService().playlists;
      if (playlists.isNotEmpty) {
        final names = playlists.take(5).map((p) => '"${p.name}"').join(', ');
        return 'No encontré la playlist "$oldName". Tienes: $names.';
      }

      return 'No pude encontrar la playlist "$oldName".';
    }
  }

  /// Editar descripción de playlist
  Future<String> _editDescription(String name, String newDescription) async {
    try {
      final searchName = name.toLowerCase().trim();
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No tienes playlists creadas aún.';
      }

      var playlist = playlists.firstWhere(
        (p) => p.name.toLowerCase().trim() == searchName,
        orElse: () => playlists.firstWhere(
          (p) =>
              p.name.toLowerCase().contains(searchName) ||
              searchName.contains(p.name.toLowerCase()),
          orElse: () => throw Exception('Playlist no encontrada'),
        ),
      );

      await PlaylistService().updatePlaylist(
        playlist.id,
        description: newDescription,
      );

      print('[GroqAssistant] ✓ Updated description for "${playlist.name}"');
      return '✓ Actualicé la descripción de "${playlist.name}".';
    } catch (e) {
      print('[GroqAssistant] Error editing description: $e');
      return 'No pude encontrar la playlist "$name".';
    }
  }

  /// Eliminar playlist
  Future<String> _deletePlaylist(String name) async {
    try {
      final searchName = name.toLowerCase().trim();
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No tienes playlists para eliminar.';
      }

      var playlist = playlists.firstWhere(
        (p) => p.name.toLowerCase().trim() == searchName,
        orElse: () => playlists.firstWhere(
          (p) =>
              p.name.toLowerCase().contains(searchName) ||
              searchName.contains(p.name.toLowerCase()),
          orElse: () => throw Exception('Playlist no encontrada'),
        ),
      );

      await PlaylistService().deletePlaylist(playlist.id);

      print('[GroqAssistant] ✓ Deleted playlist "${playlist.name}"');
      return '✓ Eliminé la playlist "${playlist.name}".';
    } catch (e) {
      print('[GroqAssistant] Error deleting playlist: $e');

      final playlists = PlaylistService().playlists;
      if (playlists.isNotEmpty) {
        final names = playlists.take(5).map((p) => '"${p.name}"').join(', ');
        return 'No encontré la playlist "$name". Tienes: $names.';
      }

      return 'No pude encontrar la playlist "$name".';
    }
  }

  /// Eliminar canción de playlist
  Future<String> _removeSong(String playlistName, String songTitle) async {
    try {
      final searchName = playlistName.toLowerCase().trim();
      final playlists = PlaylistService().playlists;

      if (playlists.isEmpty) {
        return 'No tienes playlists creadas.';
      }

      var playlist = playlists.firstWhere(
        (p) => p.name.toLowerCase().trim() == searchName,
        orElse: () => playlists.firstWhere(
          (p) =>
              p.name.toLowerCase().contains(searchName) ||
              searchName.contains(p.name.toLowerCase()),
          orElse: () => throw Exception('Playlist no encontrada'),
        ),
      );

      // Buscar la canción en la playlist
      final song = playlist.songs.firstWhere(
        (s) =>
            s.title.toLowerCase().contains(songTitle.toLowerCase()) ||
            songTitle.toLowerCase().contains(s.title.toLowerCase()),
        orElse: () => throw Exception('Canción no encontrada'),
      );

      await PlaylistService().removeSongFromPlaylist(playlist.id, song.id);

      print(
        '[GroqAssistant] ✓ Removed "${song.title}" from "${playlist.name}"',
      );
      return '✓ Eliminé "${song.title}" de "${playlist.name}".';
    } catch (e) {
      print('[GroqAssistant] Error removing song: $e');

      if (e.toString().contains('Canción no encontrada')) {
        return 'No encontré la canción "$songTitle" en la playlist "$playlistName".';
      }

      return 'No pude encontrar la playlist "$playlistName".';
    }
  }

  /// Limpiar historial de conversación
  void clearHistory() {
    _conversationHistory.clear();
  }

  /// Obtener historial de conversación
  List<Map<String, String>> get conversationHistory =>
      List.unmodifiable(_conversationHistory);
}
