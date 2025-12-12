
enum AIProvider { groq, gemini, gptOss }

class ApiConfig {
  // ============================================================================
  // CONFIGURACIÓN GENERAL
  // ============================================================================
  /// Proveedor de IA activo (cambia esto para usar otra API)
  static const AIProvider activeProvider = AIProvider.gptOss;

  // ============================================================================
  // DORRATZ API (GPT OSS)
  // ============================================================================
  static const String dorratzBaseUrl = 'https://api.dorratz.com';
  static const String dorratzGptEndpoint = '$dorratzBaseUrl/ai/gpt';

  // ============================================================================
  // GROQ API (RECOMENDADO - Rápido y Gratuito)
  // ============================================================================
  /// Obtén tu key en: https://console.groq.com/keys
  static const String groqApiKey =
      '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';
  static const String groqEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';

  /// Modelos disponibles:
  /// - llama-3.3-70b-versatile (recomendado)
  /// - llama-3.1-70b-versatile
  /// - mixtral-8x7b-32768
  /// - gemma2-9b-it
  static const String groqModel = 'llama-3.3-70b-versatile';

  // ============================================================================
  // GOOGLE GEMINI API (Gratuito)
  // ============================================================================
  /// Obtén tu key en: https://aistudio.google.com/app/apikey
  static const String geminiApiKey = 'AIzaSyDH93cpdCWwduKDx3Dwy-pqrz4NX4w_s4k';
  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Modelos disponibles:
  /// - gemini-1.5-flash (recomendado, rápido)
  /// - gemini-1.5-pro (más capaz)
  static const String geminiModel = 'gemini-1.5-flash';

  // ============================================================================
  // GITHUB API
  // ============================================================================
  static const String githubRepoOwner = 'Frantt21';
  static const String githubRepoName = 'forawn';
  static const String githubApiUrl = 'https://api.github.com';

  // ============================================================================
  // GETTERS DINÁMICOS SEGÚN PROVEEDOR ACTIVO
  // ============================================================================
  static String get currentApiKey {
    switch (activeProvider) {
      case AIProvider.groq:
        return groqApiKey;
      case AIProvider.gemini:
        return geminiApiKey;
      case AIProvider.gptOss:
        return ''; // No API key required for this endpoint
    }
  }

  static String get currentEndpoint {
    switch (activeProvider) {
      case AIProvider.groq:
        return groqEndpoint;
      case AIProvider.gemini:
        return '$geminiEndpoint/$geminiModel:generateContent';
      case AIProvider.gptOss:
        return dorratzGptEndpoint;
    }
  }

  static String get currentModel {
    switch (activeProvider) {
      case AIProvider.groq:
        return groqModel;
      case AIProvider.gemini:
        return geminiModel;
      case AIProvider.gptOss:
        return 'gpt-4 (OSS)';
    }
  }

  static String get currentProviderName {
    switch (activeProvider) {
      case AIProvider.groq:
        return 'Groq';
      case AIProvider.gemini:
        return 'Google Gemini';
      case AIProvider.gptOss:
        return 'GPT OSS';
    }
  }

  // ============================================================================
  // VALIDACIONES
  // ============================================================================
  static bool get isCurrentProviderConfigured {
    if (activeProvider == AIProvider.gptOss) return true; // Always configured
    final key = currentApiKey;
    return key.isNotEmpty && !key.contains('TU_') && !key.contains('AQUI');
  }

  static String get notConfiguredMessage =>
      'Error: API key de $currentProviderName no configurada.\n\n'
      'Por favor configura tu API key en lib/config/api_config.dart\n\n'
      '${_getProviderInstructions()}';

  static String _getProviderInstructions() {
    switch (activeProvider) {
      case AIProvider.groq:
        return '1. Visita: https://console.groq.com/keys\n'
            '2. Crea una cuenta gratuita\n'
            '3. Genera una API key\n'
            '4. Reemplaza la key en api_config.dart';
      case AIProvider.gemini:
        return '1. Visita: https://aistudio.google.com/app/apikey\n'
            '2. Inicia sesión con tu cuenta de Google\n'
            '3. Genera una API key\n'
            '4. Reemplaza la key en api_config.dart';
      case AIProvider.gptOss:
        return 'No requiere configuración adicional.';
    }
  }

  // ============================================================================
  // MÉTODOS AUXILIARES PARA SELECTOR DE MODELO
  // ============================================================================

  /// Obtiene la API key del proveedor especificado
  static String getApiKeyForProvider(AIProvider provider) {
    switch (provider) {
      case AIProvider.groq:
        return groqApiKey;
      case AIProvider.gemini:
        return geminiApiKey;
      case AIProvider.gptOss:
        return '';
    }
  }

  /// Obtiene el endpoint del proveedor especificado
  static String getEndpointForProvider(AIProvider provider) {
    switch (provider) {
      case AIProvider.groq:
        return groqEndpoint;
      case AIProvider.gemini:
        return '$geminiEndpoint/$geminiModel:generateContent';
      case AIProvider.gptOss:
        return dorratzGptEndpoint;
    }
  }

  /// Obtiene el modelo del proveedor especificado
  static String getModelForProvider(AIProvider provider) {
    switch (provider) {
      case AIProvider.groq:
        return groqModel;
      case AIProvider.gemini:
        return geminiModel;
      case AIProvider.gptOss:
        return 'gpt-4';
    }
  }

  /// Obtiene el nombre legible del proveedor
  static String getProviderName(AIProvider provider) {
    switch (provider) {
      case AIProvider.groq:
        return 'Groq';
      case AIProvider.gemini:
        return 'Gemini';
      case AIProvider.gptOss:
        return 'GPT OSS';
    }
  }

  /// Verifica si un proveedor específico está configurado
  static bool isProviderConfigured(AIProvider provider) {
    if (provider == AIProvider.gptOss) return true;
    final key = getApiKeyForProvider(provider);
    return key.isNotEmpty && !key.contains('TU_') && !key.contains('AQUI');
  }

  // ============================================================================
  // DOWNLOAD SERVICES APIs
  // ============================================================================

  // --- SPOTIFY APIs ---
  static const String spotifySearchUrl = '$dorratzBaseUrl/spotifysearch';
  static const String spotifyDownloadUrl = '$dorratzBaseUrl/spotifydl';

  // RapidAPI Spotify endpoints (fallback)
  static const String rapidApiSpotifyDownloader =
      'https://spotify-downloader9.p.rapidapi.com/downloadSong';
  static const String rapidApiSpotifyMusicMp3 =
      'https://spotify-music-mp3-downloader-api.p.rapidapi.com/download';
  static const String rapidApiSpotify246 =
      'https://spotify246.p.rapidapi.com/audio';

  // --- YOUTUBE APIs ---
  static const String ytmp3NuSearch = 'https://ytmp3.nu/api/ajaxSearch';
  static const String ytmp3NuConvert = 'https://ytmp3.nu/api/ajaxConvert';

  // RapidAPI YouTube endpoints (fallback)
  static const String rapidApiYoutubeMp36 =
      'https://youtube-mp36.p.rapidapi.com/dl';
  static const String rapidApiYtSearchDownload =
      'https://yt-search-and-download-mp3.p.rapidapi.com/mp3';
  static const String rapidApiYoutubeMp32025 =
      'https://youtube-mp3-2025.p.rapidapi.com/v1/social/youtube/audio';
  static const String rapidApiYoutubeMp4Mp3 =
      'https://youtube-mp4-mp3-m4a-cdn.p.rapidapi.com/audio';

  // --- IMAGE GENERATION API ---
  static const String imageGenerationUrl = '$dorratzBaseUrl/v3/ai-image';

  // --- PINTEREST IMAGE SEARCH API ---
  static const String pinterestSearchUrl = '$dorratzBaseUrl/v2/pinterest';

  // --- TRANSLATION API ---
  static const String translationUrl = '$dorratzBaseUrl/v3/translate';

  // --- RAPIDAPI KEY (si se usa) ---
  static const String rapidApiKey = 'TU_RAPIDAPI_KEY_AQUI'; // Opcional

  // ============================================================================
  // HELPER METHODS PARA DOWNLOAD SERVICES
  // ============================================================================

  /// Construye URL de búsqueda de Spotify
  static String getSpotifySearchUrl(String query) {
    final encoded = Uri.encodeComponent(query);
    return '$spotifySearchUrl?query=$encoded';
  }

  /// Construye URL de descarga de Spotify
  static String getSpotifyDownloadUrl(String url) {
    final encoded = Uri.encodeComponent(url);
    return '$spotifyDownloadUrl?url=$encoded';
  }

  /// Construye URL de generación de imagen
  static String getImageGenerationUrl(String prompt, String ratio) {
    final encoded = Uri.encodeComponent(prompt);
    return '$imageGenerationUrl?prompt=$encoded&ratio=$ratio';
  }

  /// Construye URL de búsqueda de imágenes en Pinterest
  static String getPinterestSearchUrl(String query) {
    final encoded = Uri.encodeComponent(query);
    return '$pinterestSearchUrl?q=$encoded';
  }

  /// Construye URL de traducción
  static String getTranslationUrl(String text, String targetCode) {
    final encoded = Uri.encodeComponent(text);
    return '$translationUrl?text=$encoded&country=$targetCode';
  }

  /// Headers para RapidAPI (si se usa)
  static Map<String, String> get rapidApiHeaders => {
    'X-RapidAPI-Key': rapidApiKey,
    'X-RapidAPI-Host': '', // Se debe especificar según el endpoint
  };
}
