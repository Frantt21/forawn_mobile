import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../config/api_config.dart';
import '../utils/safe_http_mixin.dart';

/// Token para cancelar peticiones HTTP
class CancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }

  void checkCancelled() {
    if (_isCancelled) {
      throw TimeoutException('Request was cancelled', null);
    }
  }
}

class ForaaiScreen extends StatefulWidget {
  const ForaaiScreen({super.key});

  @override
  State<ForaaiScreen> createState() => ForaaiScreenState();
}

class ForaaiScreenState extends State<ForaaiScreen> with SafeHttpMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();

  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _sidebarOpen = false; // Cerrado por defecto en móvil
  AIProvider _selectedProvider = ApiConfig.activeProvider;
  File? _selectedImage;

  // Sistema de límites
  final Map<AIProvider, int> _apiCallsRemaining = {};
  final Map<AIProvider, DateTime> _lastResetTime = {};

  // HTTP request management
  http.Client? _httpClient;
  final List<CancelToken> _pendingRequests = [];

  @override
  void initState() {
    super.initState();
    _httpClient = http.Client();
    _loadSessions();
    _loadRateLimits();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    // Cancelar todas las peticiones pendientes
    for (final token in _pendingRequests) {
      token.cancel();
    }
    _pendingRequests.clear();

    // Cerrar cliente HTTP
    _httpClient?.close();

    // Limpiar controladores
    _focusNode.dispose();
    _controller.dispose();
    _scrollController.dispose();

    // SafeHttpMixin se encarga de limpiar sus recursos
    super.dispose();
  }

  // ============================================================================
  // SISTEMA DE LÍMITES DE LLAMADAS
  // ============================================================================

  static const Map<AIProvider, int> _rateLimits = {
    AIProvider.groq: 50,
    AIProvider.gemini: 30,
    AIProvider.gptOss: 1000000,
  };

  Future<void> _loadRateLimits() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    for (var provider in AIProvider.values) {
      final key = 'rate_limit_${provider.name}';
      final remaining = prefs.getInt(key) ?? _rateLimits[provider]!;
      final lastReset = prefs.getString('${key}_reset');

      _apiCallsRemaining[provider] = remaining;
      _lastResetTime[provider] = lastReset != null
          ? DateTime.parse(lastReset)
          : DateTime.now();
    }

    setState(() {});
    _checkAndResetLimits();
  }

  Future<void> _saveRateLimits() async {
    final prefs = await SharedPreferences.getInstance();

    for (var provider in AIProvider.values) {
      final key = 'rate_limit_${provider.name}';
      await prefs.setInt(key, _apiCallsRemaining[provider] ?? 0);
      await prefs.setString(
        '${key}_reset',
        _lastResetTime[provider]!.toIso8601String(),
      );
    }
  }

  void _checkAndResetLimits() {
    final now = DateTime.now();
    bool needsSave = false;

    for (var provider in AIProvider.values) {
      final lastReset = _lastResetTime[provider]!;
      final hoursSinceReset = now.difference(lastReset).inHours;

      if (hoursSinceReset >= 1) {
        _apiCallsRemaining[provider] = _rateLimits[provider]!;
        _lastResetTime[provider] = now;
        needsSave = true;
      }
    }

    if (needsSave) {
      setState(() {});
      _saveRateLimits();
    }
  }

  bool _canMakeApiCall(AIProvider provider) {
    _checkAndResetLimits();
    return (_apiCallsRemaining[provider] ?? 0) > 0;
  }

  void _decrementApiCall(AIProvider provider) {
    if (_apiCallsRemaining[provider] != null &&
        _apiCallsRemaining[provider]! > 0) {
      _apiCallsRemaining[provider] = _apiCallsRemaining[provider]! - 1;
      setState(() {});
      _saveRateLimits();
    }
  }

  String _getTimeUntilReset(AIProvider provider) {
    final lastReset = _lastResetTime[provider];
    if (lastReset == null) return '60 min';

    final nextReset = lastReset.add(const Duration(hours: 1));
    final diff = nextReset.difference(DateTime.now());

    if (diff.inMinutes <= 0) return '0 min';
    return '${diff.inMinutes} min';
  }

  // ============================================================================
  // GESTIÓN DE SESIONES
  // ============================================================================

  Future<void> _loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final sessionsJson = prefs.getStringList('foraai_sessions') ?? [];

      setState(() {
        _sessions =
            sessionsJson
                .map((s) => ChatSession.fromJson(jsonDecode(s)))
                .toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

        // NO cargar automáticamente ninguna sesión
        // El usuario debe seleccionar una o crear una nueva
        if (_sessions.isEmpty) {
          _createNewSession();
        }
        // Si hay sesiones, dejar _currentSessionId como null
        // para mostrar una pantalla vacía
      });
    } catch (e) {
      debugPrint('Error loading sessions: $e');
      setState(() {
        _sessions = [];
        _createNewSession();
      });
    }
  }

  Future<void> _saveSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = _sessions.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('foraai_sessions', sessionsJson);
  }

  void _createNewSession() {
    final newSession = ChatSession(
      id: const Uuid().v4(),
      title: 'Nuevo Chat',
      messages: [],
      timestamp: DateTime.now(),
    );
    setState(() {
      _sessions.insert(0, newSession);
      _currentSessionId = newSession.id;
    });
    _saveSessions();
  }

  void _deleteSession(String id) {
    setState(() {
      _sessions.removeWhere((s) => s.id == id);
      if (_currentSessionId == id) {
        if (_sessions.isNotEmpty) {
          _currentSessionId = _sessions.first.id;
        } else {
          _createNewSession();
        }
      }
    });
    _saveSessions();
  }

  ChatSession? get _currentSession {
    try {
      return _sessions.firstWhere((s) => s.id == _currentSessionId);
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // SELECTOR DE IMAGEN
  // ============================================================================

  Future<void> _pickImage() async {
    if (_selectedProvider != AIProvider.gemini) {
      _showSnackBar('Las imágenes solo están disponibles con Gemini');
      return;
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _selectedImage = File(image.path);
        });
      }
    } catch (e) {
      _showSnackBar('Error al seleccionar imagen: $e');
    }
  }

  void _removeImage() {
    setState(() {
      _selectedImage = null;
    });
  }

  // ============================================================================
  // API CALLS
  // ============================================================================

  List<Map<String, dynamic>> _buildMessagesForAPI(
    ChatSession session,
    String newUserText,
  ) {
    const int maxChars = 4000;
    int total = 0;
    final List<ChatMessage> reversed = List.from(session.messages.reversed);
    final List<ChatMessage> picked = [];

    for (final m in reversed) {
      if (total + m.content.length > maxChars) break;
      picked.insert(0, m);
      total += m.content.length;
    }

    return [
      {
        'role': 'system',
        'content':
            'Eres un asistente de IA avanzado. Responde de forma clara, concisa y útil. '
            'Para código usa markdown. Siempre responde en el idioma del usuario.',
      },
      ...picked.map(
        (m) => {
          'role': m.role == 'user' ? 'user' : 'assistant',
          'content': m.content,
        },
      ),
      {'role': 'user', 'content': newUserText},
    ];
  }

  Future<String> _callGroqAPI(
    List<Map<String, dynamic>> messages,
    CancelToken token,
  ) async {
    try {
      token.checkCancelled();

      final response = await _httpClient!
          .post(
            Uri.parse(ApiConfig.getEndpointForProvider(_selectedProvider)),
            headers: {
              'Authorization':
                  'Bearer ${ApiConfig.getApiKeyForProvider(_selectedProvider)}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': ApiConfig.getModelForProvider(_selectedProvider),
              'messages': messages,
              'temperature': 0.7,
              'max_tokens': 1024,
            }),
          )
          .timeout(const Duration(seconds: 30));

      token.checkCancelled();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        final choices = data['choices'] as List<dynamic>?;
        final content = choices?.isNotEmpty == true
            ? choices![0]['message']['content']
            : null;

        return (content is String && content.trim().isNotEmpty)
            ? content
            : 'Error: Respuesta vacía';
      } else {
        String errMsg = 'Failed (${response.statusCode})';
        try {
          final err = jsonDecode(response.body);
          errMsg =
              err['error']?['message']?.toString() ??
              err['message']?.toString() ??
              errMsg;
        } catch (_) {}
        throw Exception(errMsg);
      }
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
    }
  }

  Future<String> _callGptOssAPI(
    List<Map<String, dynamic>> messages,
    CancelToken token,
  ) async {
    try {
      token.checkCancelled();

      final StringBuffer promptBuffer = StringBuffer();

      for (final msg in messages) {
        final role = msg['role'] == 'user'
            ? 'User'
            : (msg['role'] == 'system' ? 'System' : 'AI');
        final content = msg['content'];
        promptBuffer.writeln('$role: $content');
      }

      promptBuffer.write('AI: ');

      final prompt = promptBuffer.toString();
      final encodedPrompt = Uri.encodeComponent(prompt);
      final url = '${ApiConfig.dorratzGptEndpoint}?prompt=$encodedPrompt';

      final response = await _httpClient!
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 45));

      token.checkCancelled();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final data = jsonDecode(response.body);
          final result = data['result'];

          if (result != null && result is String) {
            String cleanResult = result;
            if (cleanResult.startsWith('"') &&
                cleanResult.endsWith('"') &&
                cleanResult.length > 1) {
              cleanResult = cleanResult.substring(1, cleanResult.length - 1);
            }

            cleanResult = cleanResult
                .replaceAll(r'\n', '\n')
                .replaceAll(r'\"', '"')
                .replaceAll(r'\t', '\t');

            return cleanResult;
          } else {
            return 'Error: Formato de respuesta inesperado';
          }
        } catch (e) {
          if (response.body.isNotEmpty) return response.body;
          return 'Error parseando respuesta: $e';
        }
      } else {
        throw Exception('Failed (${response.statusCode}): ${response.body}');
      }
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
    }
  }

  Future<String> _callGeminiAPI(
    List<Map<String, dynamic>> messages, {
    File? imageFile,
    required CancelToken token,
  }) async {
    try {
      token.checkCancelled();

      final contents = <Map<String, dynamic>>[];

      for (var msg in messages.where((m) => m['role'] != 'system')) {
        contents.add({
          'role': msg['role'] == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': msg['content']},
          ],
        });
      }

      if (imageFile != null && contents.isNotEmpty) {
        final bytes = await imageFile.readAsBytes();
        final base64Image = base64Encode(bytes);

        (contents.last['parts'] as List).add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
        });
      }

      token.checkCancelled();

      final systemMsg = messages.firstWhere(
        (m) => m['role'] == 'system',
        orElse: () => {'content': ''},
      )['content'];
      if (systemMsg!.isNotEmpty && contents.isNotEmpty) {
        final firstPart = (contents.first['parts'] as List).first;
        firstPart['text'] = '$systemMsg\n\n${firstPart['text']}';
      }

      final model = ApiConfig.getModelForProvider(_selectedProvider);
      final endpoint = '${ApiConfig.geminiEndpoint}/$model:generateContent';
      final apiKey = ApiConfig.getApiKeyForProvider(_selectedProvider);

      final response = await _httpClient!
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode({
              'contents': contents,
              'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 2048},
            }),
          )
          .timeout(const Duration(seconds: 30));

      token.checkCancelled();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        return data['candidates']?[0]?['content']?['parts']?[0]?['text'] ??
            'Error: Respuesta vacía';
      } else {
        String errorMsg = 'HTTP ${response.statusCode}';
        try {
          final errorData = jsonDecode(response.body);
          errorMsg = errorData['error']?['message'] ?? errorMsg;
        } catch (_) {
          errorMsg = response.body;
        }
        throw Exception(errorMsg);
      }
    } on TimeoutException {
      if (token.isCancelled) {
        throw TimeoutException('Request cancelled', null);
      }
      rethrow;
    }
  }

  Future<void> _sendMessage({
    String? manualText,
    bool isRegenerate = false,
  }) async {
    final text = manualText ?? _controller.text.trim();
    if (text.isEmpty) return;

    final session = _currentSession;
    if (session == null) return;

    if (!_canMakeApiCall(_selectedProvider)) {
      _showSnackBar(
        'Límite alcanzado. Se restablecerá en ${_getTimeUntilReset(_selectedProvider)}',
      );
      return;
    }

    if (!ApiConfig.isProviderConfigured(_selectedProvider)) {
      _showSnackBar(
        'API key no configurada: ${ApiConfig.getProviderName(_selectedProvider)}',
      );
      return;
    }

    if (!isRegenerate) {
      _controller.clear();

      setState(() {
        session.messages.add(
          ChatMessage(
            role: 'user',
            content: text,
            imagePath: _selectedImage?.path,
          ),
        );
        session.timestamp = DateTime.now();
        _sessions.remove(session);
        _sessions.insert(0, session);
        _isLoading = true;
      });
      _focusNode.requestFocus();
    } else {
      setState(() => _isLoading = true);
    }

    _scrollToBottom();
    _saveSessions();

    if (session.messages.length == 1) {
      setState(() {
        session.title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
      });
    }

    try {
      final messages = _buildMessagesForAPI(session, text);
      String result;

      final cancelToken = CancelToken();
      _pendingRequests.add(cancelToken);

      try {
        switch (_selectedProvider) {
          case AIProvider.groq:
            result = await _callGroqAPI(messages, cancelToken);
            break;
          case AIProvider.gptOss:
            result = await _callGptOssAPI(messages, cancelToken);
            break;
          case AIProvider.gemini:
            result = await _callGeminiAPI(
              messages,
              imageFile: _selectedImage,
              token: cancelToken,
            );
            break;
        }
      } finally {
        _pendingRequests.remove(cancelToken);
      }

      _decrementApiCall(_selectedProvider);

      final hadImage = _selectedImage != null;
      if (_selectedImage != null) {
        safeSetState(() => _selectedImage = null);
      }

      if (mounted) {
        safeSetState(() {
          session.messages.add(ChatMessage(role: 'ai', content: result));
          _isLoading = false;
        });
        _scrollToBottom();
        _saveSessions();

        if (hadImage) {
          _showSnackBar('✓ Imagen procesada correctamente');
        }
      }
    } catch (e) {
      if (mounted) {
        final isCancelled =
            e is TimeoutException && e.message == 'Request was cancelled';

        safeSetState(() {
          session.messages.add(
            ChatMessage(
              role: 'ai',
              content: isCancelled
                  ? '⏸ Cancelado'
                  : 'Error (${ApiConfig.getProviderName(_selectedProvider)}): $e',
            ),
          );
          _isLoading = false;
          _selectedImage = null;
        });
        _scrollToBottom();
        _saveSessions();
      }
    }
  }

  void _regenerateLastResponse() {
    final session = _currentSession;
    if (session == null || session.messages.isEmpty) return;

    if (session.messages.last.role == 'ai') {
      setState(() => session.messages.removeLast());

      if (session.messages.isNotEmpty && session.messages.last.role == 'user') {
        final lastUserMessage = session.messages.last.content;
        setState(() => session.messages.removeLast());
        _sendMessage(manualText: lastUserMessage, isRegenerate: true);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2C2C2C),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Método público para abrir/cerrar sidebar desde el padre
  void toggleSidebar() {
    setState(() => _sidebarOpen = !_sidebarOpen);
  }

  // Getter para saber si el sidebar está abierto
  bool get isSidebarOpen => _sidebarOpen;

  @override
  Widget build(BuildContext context) {
    final session = _currentSession;

    return Stack(
      children: [
        // Contenido principal
        Scaffold(
          backgroundColor: Colors.transparent,
          body: session == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.smart_toy_outlined,
                          size: 80,
                          color: Colors.purpleAccent.withOpacity(0.5),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Bienvenido a ForaAI',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Selecciona una conversación del menú\no crea una nueva para comenzar',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    top: 16,
                    left: 16,
                    right: 16,
                    bottom: 180, // Espacio para el input flotante
                  ),
                  itemCount: session.messages.length + (_isLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index < session.messages.length) {
                      final msg = session.messages[index];
                      final isLast = index == session.messages.length - 1;
                      return _buildMessageBubble(msg, isLast: isLast);
                    } else {
                      return _buildLoadingBubble();
                    }
                  },
                ),
        ),

        // Input Flotante
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(child: _buildInputArea()),
        ),

        // Drawer lateral (overlay)
        if (_sidebarOpen)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 280,
              decoration: BoxDecoration(
                color: const Color(0xFF1a1a1a),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 10,
                    offset: const Offset(2, 0),
                  ),
                ],
              ),
              child: _buildDrawerContent(),
            ),
          ),

        // Overlay oscuro cuando el drawer está abierto
        if (_sidebarOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _sidebarOpen = false),
              child: Container(
                color: Colors.black.withOpacity(0.3),
                margin: const EdgeInsets.only(left: 280),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDrawerContent() {
    return Column(
      children: [
        // Botón Nuevo Chat (sin DrawerHeader)
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            onPressed: _createNewSession,
            icon: const Icon(Icons.add),
            label: const Text('Nuevo Chat'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purpleAccent.withOpacity(0.2),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 45),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _sessions.length,
            itemBuilder: (context, index) {
              final s = _sessions[index];
              final isSelected = s.id == _currentSessionId;
              return ListTile(
                title: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                selected: isSelected,
                selectedTileColor: Colors.white.withOpacity(0.05),
                onTap: () {
                  setState(() {
                    _currentSessionId = s.id;
                    _sidebarOpen = false; // Cerrar sidebar al seleccionar
                  });
                  _scrollToBottom();
                },
                trailing: isSelected
                    ? IconButton(
                        icon: const Icon(
                          Icons.delete,
                          size: 16,
                          color: Colors.white54,
                        ),
                        onPressed: () => _deleteSession(s.id),
                      )
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInputArea() {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedImage != null) _buildImagePreview(),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: const TextStyle(color: Colors.white),
            maxLines: null,
            minLines: 1,
            decoration: InputDecoration(
              hintText: 'Escribe un mensaje...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              isDense: true,
            ),
            onSubmitted: (_) => _sendMessage(),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (_selectedProvider == AIProvider.gemini)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: _isLoading ? null : _pickImage,
                            borderRadius: BorderRadius.circular(20),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.add_photo_alternate_rounded,
                                size: 20,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      _buildSmallProviderSelector(),
                      const SizedBox(width: 8),
                      Text(
                        '${_apiCallsRemaining[_selectedProvider]}/${_rateLimits[_selectedProvider]} • ${_getTimeUntilReset(_selectedProvider)}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.3),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: _isLoading ? null : () => _sendMessage(),
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: _isLoading
                      ? Colors.white10
                      : Colors.purpleAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(10),
                  minimumSize: const Size(40, 40),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea_Deprecated() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selectedImage != null) _buildImagePreview(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_selectedProvider == AIProvider.gemini)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: IconButton(
                    onPressed: _isLoading ? null : _pickImage,
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Escribe un mensaje...',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  onPressed: _isLoading ? null : () => _sendMessage(),
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_upward_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: _isLoading
                        ? Colors.white10
                        : Colors.purpleAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(10),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
            child: Row(
              children: [
                _buildSmallProviderSelector(),
                const SizedBox(width: 12),
                Text(
                  '${_apiCallsRemaining[_selectedProvider]}/${_rateLimits[_selectedProvider]} • ${_getTimeUntilReset(_selectedProvider)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallProviderSelector() {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AIProvider>(
          value: _selectedProvider,
          dropdownColor: const Color(0xFF2d2d2d),
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 14,
            color: Colors.white54,
          ),
          isDense: true,
          style: const TextStyle(color: Colors.white, fontSize: 11),
          onChanged: _isLoading
              ? null
              : (AIProvider? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _selectedProvider = newValue;
                      _selectedImage = null;
                    });
                  }
                },
          items: AIProvider.values.map((AIProvider provider) {
            return DropdownMenuItem<AIProvider>(
              value: provider,
              child: Text(ApiConfig.getProviderName(provider)),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.purpleAccent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              _selectedImage!,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Imagen lista para enviar',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          IconButton(
            onPressed: _removeImage,
            icon: const Icon(Icons.close, size: 18),
            style: IconButton.styleFrom(foregroundColor: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, {required bool isLast}) {
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(16),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? Colors.purpleAccent.withOpacity(0.2)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: isUser ? const Radius.circular(16) : Radius.zero,
                bottomRight: isUser ? Radius.zero : const Radius.circular(16),
              ),
              border: Border.all(
                color: isUser
                    ? Colors.purpleAccent.withOpacity(0.3)
                    : Colors.white.withOpacity(0.1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (msg.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 200,
                          maxWidth: 200,
                        ),
                        child: Image.file(
                          File(msg.imagePath!),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const Text(
                                '[Imagen no disponible]',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ),
                if (!isUser) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.auto_awesome,
                        size: 16,
                        color: Colors.purpleAccent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'ForaAI',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.purpleAccent.withOpacity(0.8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                isUser
                    ? SelectableText(
                        msg.content,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Colors.white,
                        ),
                      )
                    : MarkdownBody(
                        data: msg.content,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Colors.white,
                          ),
                          code: TextStyle(
                            backgroundColor: Colors.black.withOpacity(0.3),
                            fontFamily: 'monospace',
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
              ],
            ),
          ),
          if (!isUser && isLast)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: TextButton.icon(
                onPressed: _isLoading ? null : _regenerateLastResponse,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Regenerar', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: const SizedBox(
          width: 40,
          height: 20,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }
}

// ====== CLASES AUXILIARES ======

class ChatSession {
  String id;
  String title;
  List<ChatMessage> messages;
  DateTime timestamp;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'timestamp': timestamp.toIso8601String(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'],
      title: json['title'],
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  final String? imagePath;

  ChatMessage({required this.role, required this.content, this.imagePath});

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (imagePath != null) 'imagePath': imagePath,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'],
    content: json['content'],
    imagePath: json['imagePath'],
  );
}
