import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../services/playlist_service.dart';
import '../models/song.dart';

class GroqAssistantService {
  // Usar configuración centralizada
  static String get _apiUrl => ApiConfig.groqEndpoint;
  static String get _apiKey => ApiConfig.groqApiKey;
  static String get _model => ApiConfig.groqModel;

  final List<Map<String, String>> _conversationHistory = [];
  List<Song> _availableSongs = [];

  /// Configurar canciones disponibles (llamar desde la UI que ya tiene las canciones)
  void setAvailableSongs(List<Song> songs) {
    _availableSongs = songs;
    print('[GroqAssistant] Set ${_availableSongs.length} available songs');
  }

  /// Enviar mensaje al asistente
  Future<String> sendMessage(String userMessage) async {
    try {
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

FORMATO PARA CREAR PLAYLIST:
Cuando el usuario pida crear una playlist, responde EXACTAMENTE en este formato JSON:
{
  "action": "create_playlist",
  "name": "Nombre de la Playlist",
  "description": "Descripción breve",
  "songs": ["Título Canción 1", "Título Canción 2", "Título Canción 3"]
}

IMPORTANTE:
- Usa SOLO canciones que existen en la biblioteca
- Los títulos deben coincidir con los de la biblioteca
- Si no hay suficientes canciones, usa las que haya disponibles

Para conversación normal, responde texto amigable en español.''',
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
    if (_availableSongs.isEmpty) {
      return 'No hay canciones disponibles. Pídele al usuario que vaya a "Local Music" primero.';
    }

    // Limitar a 30 canciones para no saturar el prompt
    final limitedSongs = _availableSongs.take(30).toList();
    final songList = limitedSongs
        .map((s) => '- "${s.title}" por ${s.artist}')
        .join('\n');

    return '''
Total de canciones: ${_availableSongs.length}
Canciones (mostrando ${limitedSongs.length}):
$songList
''';
  }

  /// Procesar acciones del asistente
  Future<void> _processAction(String message) async {
    try {
      // Buscar JSON en el mensaje
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(message);
      if (jsonMatch != null) {
        final jsonStr = jsonMatch.group(0)!;
        final action = jsonDecode(jsonStr);

        if (action['action'] == 'create_playlist') {
          await _createPlaylist(
            action['name'] as String,
            action['description'] as String?,
            (action['songs'] as List<dynamic>?)?.cast<String>(),
          );
        }
      }
    } catch (e) {
      print('[GroqAssistant] Not an action or error processing: $e');
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
