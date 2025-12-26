/// Utilidades para procesamiento de texto
///
/// Incluye funciones para:
/// - Normalización de texto (búsqueda sin acentos)
/// - Remoción de acentos
/// - Capitalización
/// - Truncado inteligente
class TextUtils {
  /// Normaliza texto para búsqueda (lowercase + sin acentos)
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.normalize("Canción Española") // "cancion espanola"
  /// ```
  static String normalize(String text) {
    return removeAccents(text.toLowerCase());
  }

  /// Remueve acentos y caracteres especiales del español
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.removeAccents("Canción") // "Cancion"
  /// ```
  static String removeAccents(String text) {
    return text
        .replaceAll('á', 'a')
        .replaceAll('Á', 'A')
        .replaceAll('é', 'e')
        .replaceAll('É', 'E')
        .replaceAll('í', 'i')
        .replaceAll('Í', 'I')
        .replaceAll('ó', 'o')
        .replaceAll('Ó', 'O')
        .replaceAll('ú', 'u')
        .replaceAll('Ú', 'U')
        .replaceAll('ñ', 'n')
        .replaceAll('Ñ', 'N')
        .replaceAll('ü', 'u')
        .replaceAll('Ü', 'U');
  }

  /// Capitaliza la primera letra de cada palabra
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.capitalize("hola mundo") // "Hola Mundo"
  /// ```
  static String capitalize(String text) {
    if (text.isEmpty) return text;

    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  /// Capitaliza solo la primera letra del texto completo
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.capitalizeFirst("hola mundo") // "Hola mundo"
  /// ```
  static String capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  /// Trunca texto a una longitud máxima con ellipsis
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.truncate("Texto muy largo", 10) // "Texto m..."
  /// ```
  static String truncate(
    String text,
    int maxLength, {
    String ellipsis = '...',
  }) {
    if (text.length <= maxLength) return text;

    final truncated = text.substring(0, maxLength - ellipsis.length);
    return '$truncated$ellipsis';
  }

  /// Trunca texto inteligentemente en el último espacio antes del límite
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.truncateSmart("Hola mundo feliz", 12) // "Hola mundo..."
  /// ```
  static String truncateSmart(
    String text,
    int maxLength, {
    String ellipsis = '...',
  }) {
    if (text.length <= maxLength) return text;

    // Buscar el último espacio antes del límite
    final truncated = text.substring(0, maxLength - ellipsis.length);
    final lastSpace = truncated.lastIndexOf(' ');

    if (lastSpace > 0) {
      return '${text.substring(0, lastSpace)}$ellipsis';
    }

    return '$truncated$ellipsis';
  }

  /// Verifica si un texto contiene otro (case insensitive, sin acentos)
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.contains("Canción Española", "cancion") // true
  /// ```
  static bool contains(String text, String query) {
    return normalize(text).contains(normalize(query));
  }

  /// Verifica si un texto comienza con otro (case insensitive, sin acentos)
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.startsWith("Canción", "can") // true
  /// ```
  static bool startsWith(String text, String query) {
    return normalize(text).startsWith(normalize(query));
  }

  /// Formatea duración en formato legible
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.formatDuration(Duration(minutes: 3, seconds: 45)) // "3:45"
  /// TextUtils.formatDuration(Duration(hours: 1, minutes: 30)) // "1:30:00"
  /// ```
  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  /// Formatea duración en formato legible largo
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.formatDurationLong(Duration(hours: 1, minutes: 30)) // "1 h 30 min"
  /// TextUtils.formatDurationLong(Duration(minutes: 45)) // "45 min"
  /// ```
  static String formatDurationLong(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '$hours h $minutes min';
    } else {
      return '$minutes min';
    }
  }

  /// Formatea tamaño de archivo en formato legible
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.formatFileSize(1024) // "1.0 KB"
  /// TextUtils.formatFileSize(1048576) // "1.0 MB"
  /// ```
  static String formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Extrae el nombre de archivo de una ruta
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.getFileName("/path/to/file.mp3") // "file.mp3"
  /// ```
  static String getFileName(String path) {
    return path.split('/').last.split('\\').last;
  }

  /// Extrae el nombre de archivo sin extensión
  ///
  /// Ejemplo:
  /// ```dart
  /// TextUtils.getFileNameWithoutExtension("/path/to/file.mp3") // "file"
  /// ```
  static String getFileNameWithoutExtension(String path) {
    final fileName = getFileName(path);
    final lastDot = fileName.lastIndexOf('.');

    if (lastDot > 0) {
      return fileName.substring(0, lastDot);
    }

    return fileName;
  }
}
