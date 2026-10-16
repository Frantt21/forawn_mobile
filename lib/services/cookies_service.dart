// lib/services/cookies_service.dart
//
// Cookies de sesión para yt-dlp (`--cookies <archivo>`).
//
// Instagram devuelve "Instagram sent an empty media response. ... use
// --cookies for the authentication" cuando el post pide sesión; con un
// archivo de cookies el extractor usa la sesión del usuario y la descarga
// funciona. En desktop yt-dlp puede leer el navegador con
// --cookies-from-browser, pero el móvil no tiene un navegador con perfil
// accesible, así que aquí las cookies se pegan UNA vez en Ajustes y se
// reutilizan en todas las descargas.
//
// El texto pegado se normaliza a un archivo en formato Netscape (el único
// que yt-dlp sabe leer) guardado en el directorio de soporte de la app.

import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda/lee las cookies del usuario y produce el archivo que consume
/// `yt-dlp --cookies`.
class CookiesService {
  static final CookiesService _instance = CookiesService._internal();
  factory CookiesService() => _instance;
  CookiesService._internal();

  /// Preferencia con el texto crudo pegado por el usuario.
  static const String prefKey = 'ytdlp_cookies_raw';

  /// Nombre del archivo Netscape que se pasa a `yt-dlp --cookies`.
  static const String fileName = 'cookies.txt';

  /// Dominio aplicado cuando el usuario pega un header `name=value` (no un
  /// cookies.txt con dominios propios). `.instagram.com` cubre
  /// www.instagram.com e i.instagram.com.
  static const String defaultDomain = '.instagram.com';

  /// Primera línea obligatoria del formato Netscape: sin ella yt-dlp aborta
  /// con "does not look like a Netscape format cookies file".
  static const String _magic = '# Netscape HTTP Cookie File';

  static const String _header =
      '$_magic\n'
      '# Generado por Forawn. Se puede borrar desde Ajustes > Cookies.\n';

  // ---------------------------------------------------------------------------
  // Persistencia
  // ---------------------------------------------------------------------------

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  /// Texto crudo guardado (vacío si no hay cookies configuradas).
  Future<String> raw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefKey)?.trim() ?? '';
  }

  /// true si hay cookies configuradas (y por lo tanto se pasa --cookies).
  Future<bool> hasCookies() async => (await raw()).isNotEmpty;

  /// Guarda las cookies pegadas por el usuario y reescribe el archivo
  /// Netscape. Un texto vacío equivale a borrar.
  Future<void> save(String input) async {
    final raw = input.trim();
    if (raw.isEmpty) {
      await clear();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, raw);
    final file = await _file();
    await file.writeAsString(buildCookieFile(raw), flush: true);
  }

  /// Borra las cookies guardadas (preferencia + archivo).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefKey);
    try {
      final file = await _file();
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Sin permisos/archivo: la preferencia ya está limpia.
    }
  }

  /// Ruta del cookies.txt listo para `yt-dlp --cookies <ruta>`, o null si el
  /// usuario no configuró cookies. Regenera el archivo si falta (por ejemplo
  /// si el sistema limpió el directorio de la app).
  Future<String?> cookieFile() async {
    final saved = await raw();
    if (saved.isEmpty) return null;
    try {
      final file = await _file();
      if (!file.existsSync()) {
        await file.writeAsString(buildCookieFile(saved), flush: true);
      }
      return file.path;
    } catch (_) {
      // Sin archivo no se puede autenticar: la descarga sigue anónima.
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Normalización del texto pegado (funciones puras -> testeables)
  // ---------------------------------------------------------------------------

  /// Convierte lo pegado por el usuario en un cookies.txt (Netscape).
  ///
  /// Acepta:
  ///  (a) el JSON que exportan las extensiones (array de cookies o
  ///      `{"cookies": [...]}`), con sus dominios ya resueltos,
  ///  (b) un cookies.txt de Netscape (se respeta tal cual),
  ///  (c) un header de Cookie (`sessionid=x; csrftoken=y`) o
  ///  (d) el valor suelto del sessionid.
  static String buildCookieFile(String input) {
    final text = input.trim();
    if (text.isEmpty) return _header;

    // (a) Export JSON de extensiones tipo Cookie-Editor (las actuales ya no
    // ofrecen .txt, así que este es el caso habitual).
    final jsonCookies = parseJsonCookies(text);
    if (jsonCookies != null) {
      final buffer = StringBuffer(_header);
      for (final cookie in jsonCookies) {
        final domain = _str(cookie['domain']);
        final path = _str(cookie['path']);
        buffer.writeln(
          _netscapeLine(
            domain: domain.isEmpty ? defaultDomain : domain,
            // hostOnly => la cookie NO aplica a subdominios.
            includeSubdomains: cookie['hostOnly'] != true,
            path: path.isEmpty ? '/' : path,
            secure: cookie['secure'] == true,
            expiry: _expiryFromJson(cookie),
            name: _str(cookie['name']),
            value: _str(cookie['value']),
            httpOnly: cookie['httpOnly'] == true,
          ),
        );
      }
      return buffer.toString();
    }

    // (b) Ya viene en formato Netscape: se usa tal cual, asegurando que
    // lleve la línea mágica (algunas extensiones la omiten).
    if (looksLikeNetscape(text)) {
      final body = text.startsWith(_magic) ? text : '$_magic\n$text';
      return body.endsWith('\n') ? body : '$body\n';
    }

    // (c)/(d) Pares name=value sueltos: hay que inventar las columnas de
    // dominio (yt-dlp los asocia al sitio de la URL que descarga).
    final pairs = parseCookiePairs(text);
    if (pairs.isEmpty) return _header;

    final buffer = StringBuffer(_header);
    pairs.forEach((name, value) {
      buffer.writeln(
        _netscapeLine(
          domain: defaultDomain,
          includeSubdomains: true,
          path: '/',
          secure: false,
          expiry: _defaultExpiry(),
          name: name,
          value: value,
        ),
      );
    });
    return buffer.toString();
  }

  /// true si el texto parece un export JSON (array u objeto).
  static bool looksLikeJson(String input) {
    final t = input.trimLeft();
    return t.startsWith('[') || t.startsWith('{');
  }

  /// Cookies de un export JSON de extensión. Acepta un array de objetos o un
  /// objeto con la lista en 'cookies'/'Cookies'/'items'. Devuelve null si el
  /// texto no es un JSON con cookies (entonces se prueban los demás
  /// formatos).
  static List<Map<String, dynamic>>? parseJsonCookies(String input) {
    if (!looksLikeJson(input)) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(input.trim());
    } catch (_) {
      return null;
    }
    dynamic list = decoded;
    if (decoded is Map) {
      list = decoded['cookies'] ?? decoded['Cookies'] ?? decoded['items'];
    }
    if (list is! List) return null;
    final out = <Map<String, dynamic>>[];
    for (final entry in list) {
      if (entry is Map && entry['name'] != null && entry['value'] != null) {
        out.add(Map<String, dynamic>.from(entry));
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Fila del formato Netscape: domain, includeSubdomains, path, secure,
  /// expiry, name, value (separadas por tabulador). Las cookies httpOnly
  /// llevan el prefijo #HttpOnly_ en el dominio, como manda el formato.
  static String _netscapeLine({
    required String domain,
    required bool includeSubdomains,
    required String path,
    required bool secure,
    required int expiry,
    required String name,
    required String value,
    bool httpOnly = false,
  }) {
    final host = httpOnly ? '#HttpOnly_$domain' : domain;
    return [
      host,
      includeSubdomains ? 'TRUE' : 'FALSE',
      path,
      secure ? 'TRUE' : 'FALSE',
      '$expiry',
      name,
      value,
    ].join('\t');
  }

  /// Expiración lejana para cookies sin fecha: el formato exige un entero de
  /// segundos y 0 significaría "cookie de sesión" (algunos loaders la
  /// descartan).
  static int _defaultExpiry() =>
      DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch ~/
      1000;

  /// Expiración de una entrada JSON: `expirationDate`/`expires` en segundos
  /// (como exporta Chrome) o una fecha ISO.
  ///
  /// Si la fecha ya pasó (o falta) se usa una futura: el cookie jar de yt-dlp
  /// descarta en SILENCIO las cookies vencidas, y el usuario vería otra vez
  /// el muro de login sin ninguna pista. Enviando el valor, quien decide es
  /// Instagram (y su rechazo sí aparece en el error).
  static int _expiryFromJson(Map<String, dynamic> cookie) {
    final raw =
        cookie['expirationDate'] ?? cookie['expires'] ?? cookie['expiry'];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int? seconds;
    if (raw is num && raw > 0) {
      seconds = raw.toInt();
    } else if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) seconds = parsed.millisecondsSinceEpoch ~/ 1000;
    }
    if (seconds == null || seconds <= now) return _defaultExpiry();
    return seconds;
  }

  /// Cadena de un campo JSON ('' si falta o no es texto).
  static String _str(dynamic value) =>
      value is String ? value.trim() : (value == null ? '' : '$value');

  /// Extrae los pares name=value de un header de Cookie (o de una lista
  /// separada por ';'/saltos de línea). Un token largo sin '=' se toma como
  /// el valor del sessionid (caso de pegar sólo el valor).
  static Map<String, String> parseCookiePairs(String input) {
    final out = <String, String>{};
    var text = input.trim();
    if (text.toLowerCase().startsWith('cookie:')) {
      text = text.substring(7).trim();
    }
    for (var part in text.split(RegExp(r'[;\n\r]+'))) {
      part = part.trim();
      if (part.isEmpty || part.startsWith('#')) continue;
      final eq = part.indexOf('=');
      if (eq <= 0) {
        // Valor suelto (sin nombre): sólo puede ser el sessionid.
        if (RegExp(r'^[A-Za-z0-9%._\-]{16,}$').hasMatch(part)) {
          out.putIfAbsent('sessionid', () => part);
        }
        continue;
      }
      final name = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  /// El texto ya está en formato Netscape (cookies.txt) si trae la línea
  /// mágica, el prefijo #HttpOnly_ o una línea con las 7 columnas (dominio
  /// con punto + expiración numérica).
  static bool looksLikeNetscape(String input) {
    if (input.contains(_magic)) return true;
    if (input.contains('#HttpOnly_')) return true;
    final colsPattern = RegExp(r'^\d+$');
    for (final line in input.split('\n')) {
      final cols = line.trim().split('\t');
      if (cols.length >= 6 &&
          cols[0].contains('.') &&
          colsPattern.hasMatch(cols[4].trim())) {
        return true;
      }
    }
    return false;
  }

  /// true si el archivo generado contiene al menos una cookie (sirve para
  /// avisar en Ajustes cuando lo pegado no era un formato reconocible).
  static bool isUsable(String input) =>
      buildCookieFile(input).contains('\t');

  /// true si el texto pegado incluye un `sessionid` (sin él Instagram sigue
  /// pidiendo login aunque se envíen otras cookies).
  static bool containsSessionId(String input) =>
      parseCookiePairs(input).containsKey('sessionid') ||
      input.contains('sessionid');
}
