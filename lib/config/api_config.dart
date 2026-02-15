library;

class ApiConfig {
  // ============================================================================
  // GROQ API
  // ============================================================================
  static const String groqApiKey =
      'api_key';
  static const String groqEndpoint =
      'api_endpoint';
  static const String groqModel = 'model';

  // ============================================================================
  // LYRICS API
  // ============================================================================
  static const String lyricsBaseUrl = 'api_base';

  // ============================================================================
  // SERVIDORES PRINCIPALES
  // ============================================================================
  static final List<String> _backends = [
    'api_servers',
    'api_servers',
  ];
  static int _currentBackendIndex = 0;

  /// Get rotated backends for load balancing
  static List<String> getRotatedBackends() {
    final rotated = List<String>.from(_backends);
    final current = rotated.removeAt(_currentBackendIndex);
    rotated.insert(0, current);
    _currentBackendIndex = (_currentBackendIndex + 1) % _backends.length;
    return rotated;
  }

  // ============================================================================
  // HELPER METHODS PARA DOWNLOAD SERVICES
  // ============================================================================

  /// Construye URL de generación de imagen
  static String getImageGenerationUrl(String prompt, String ratio) {
    final encoded = Uri.encodeComponent(prompt);
    // Convertir ratio a dimensiones
    int width, height;
    switch (ratio) {
      case '1:1':
        width = 1024;
        height = 1024;
        break;
      case '16:9':
        width = 1920;
        height = 1080;
        break;
      case '9:16':
        width = 1080;
        height = 1920;
        break;
      case '4:3':
        width = 1024;
        height = 768;
        break;
      case '3:4':
        width = 768;
        height = 1024;
        break;
      default:
        width = 1024;
        height = 1024;
    }
    return 'api/$encoded?width=$width&height=$height&model=flux&nologo=true';
  }

  /// Construye URL de generación de imagen con Pollinations
  static String getPollinationsUrl(
    String prompt,
    int width,
    int height, {
    String model = 'flux',
  }) {
    final encodedPrompt = Uri.encodeComponent(prompt);
    return 'api/$encodedPrompt?width=$width&height=$height&model=$model&nologo=true';
  }

  /// YouTube Search URL
  static String getYouTubeSearchUrl(
    String query,
    String baseUrl, {
    int limit = 40,
  }) {
    return '$baseUrl/youtube/search?q=${Uri.encodeComponent(query)}&limit=$limit';
  }

  /// Cache Check URL
  static String getCacheCheckUrl(String title, String artist, String baseUrl) {
    return '$baseUrl/cache/check?title=${Uri.encodeComponent(title)}&artist=${Uri.encodeComponent(artist)}';
  }

  /// Construye URL de búsqueda de Spotify
  static String getSpotifySearchUrl(String query) {
    final encoded = Uri.encodeComponent(query);
    return '${_backends[0]}/metadata/search?q=$encoded';
  }

  /// Construye URL de descarga de Spotify
  static String getSpotifyDownloadUrl(String url) {
    final encoded = Uri.encodeComponent(url);
    return '${_backends[0]}/download?url=$encoded';
  }

}
