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

CAPACIDADES:
1. Crear playlists con canciones de la biblioteca
2. Recomendar música basada en mood/género
3. Buscar canciones específicas

REGLAS IMPORTANTES:
- Para CREAR PLAYLIST: Responde SOLO el JSON, sin texto adicional
- Para CONVERSACIÓN: Responde SOLO texto, sin JSON
- NO mezcles JSON con texto explicativo

FORMATO JSON PARA CREAR PLAYLIST:
{
  "action": "create_playlist",
  "name": "Nombre de la Playlist",
  "description": "Descripción breve",
  "songs": ["Canción 1", "Canción 2", "Canción 3"]
}

IMPORTANTE:
- Usa SOLO canciones que existen en la biblioteca (títulos exactos)
- Si no hay suficientes canciones del género pedido, usa las disponibles
- Para conversación normal, responde en español de forma amigable

Ejemplos:
Usuario: "Crea una playlist de reggaeton"
Tú: {"action": "create_playlist", "name": "Reggaeton Mix", "description": "Lo mejor del reggaeton", "songs": ["Tarot", "Monaco"]}

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

        // Procesar acciones (crear playlist)
        await _processAction(assistantMessage);

        return assistantMessage;
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

  /// Procesar acciones del asistente
  Future<void> _processAction(String message) async {
    try {
      print('[GroqAssistant] === PROCESSING ACTION ===');

      // Buscar JSON en el mensaje
      final jsonMatch = RegExp(r'\{[\s\S]*?\}').firstMatch(message);
      if (jsonMatch != null) {
        final jsonStr = jsonMatch.group(0)!;
        print(
          '[GroqAssistant] Found potential JSON: ${jsonStr.substring(0, jsonStr.length > 100 ? 100 : jsonStr.length)}...',
        );

        try {
          final action = jsonDecode(jsonStr);
          print('[GroqAssistant] ✓ Parsed action: ${action['action']}');

          if (action['action'] == 'create_playlist') {
            print('[GroqAssistant] Creating playlist: ${action['name']}');
            await _createPlaylist(
              action['name'] as String,
              action['description'] as String?,
              (action['songs'] as List<dynamic>?)?.cast<String>(),
            );
          }
        } catch (parseError) {
          print('[GroqAssistant] ✗ JSON parse error: $parseError');
        }
      } else {
        print('[GroqAssistant] No JSON action found');
      }
    } catch (e) {
      print('[GroqAssistant] ✗ Error processing action: $e');
    }
  }

  /// Crear playlist con canciones de la biblioteca
  Future<void> _createPlaylist(
    String name,
    String? description,
    List<String>? songTitles,
  ) async {
    try {
      final selectedSongs = <Song>[];

      if (songTitles != null && songTitles.isNotEmpty) {
        // Buscar canciones por título (fuzzy match)
        for (final title in songTitles) {
          final song = _availableSongs.firstWhere(
            (s) =>
                s.title.toLowerCase().contains(title.toLowerCase()) ||
                title.toLowerCase().contains(s.title.toLowerCase()),
            orElse: () => _availableSongs.isNotEmpty
                ? _availableSongs.first
                : Song(id: '', title: '', artist: '', filePath: ''),
          );

          if (song.id.isNotEmpty) {
            selectedSongs.add(song);
          }
        }
      }

      if (selectedSongs.isEmpty) {
        print('[GroqAssistant] No songs found for playlist');
        return;
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
    } catch (e) {
      print('[GroqAssistant] Error creating playlist: $e');
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
