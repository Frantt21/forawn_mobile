/// API Configuration - Multi-Provider Support
///
/// IMPORTANTE: Este archivo contiene tus API keys privadas
/// NO hagas commit de este archivo (está en .gitignore)
library;

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
}
