/// Generador de IDs determinísticos y estables
/// Reemplaza el uso de .hashCode que es aleatorio por sesión en Dart
class IdGenerator {
  /// Genera un ID hash estable de 32 bits para un string dado (ej. path de archivo)
  /// Algoritmo FNV-1a simple
  static String generateSongId(String path) {
    if (path.isEmpty) return '0';

    int hash = 0x811c9dc5;
    final units = path.codeUnits;

    for (int i = 0; i < units.length; i++) {
      hash ^= units[i];
      hash *= 0x01000193;
      // Forzar 32-bit unsigned simulado
      hash &= 0xFFFFFFFF;
    }

    return hash.toRadixString(16);
  }
}
