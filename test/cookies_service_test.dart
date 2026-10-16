// test/cookies_service_test.dart
//
// Pruebas de la normalización de cookies: el texto que el usuario pega en
// Ajustes se convierte en un cookies.txt (formato Netscape) que yt-dlp
// consume con --cookies. Son funciones puras: no tocan red ni plugins.
//
// Contexto: sin cookies, Instagram responde "sent an empty media response"
// y la descarga falla con error de autenticación.

import 'package:flutter_test/flutter_test.dart';
import 'package:forawn/services/cookies_service.dart';

void main() {
  const magic = '# Netscape HTTP Cookie File';

  /// Filas de cookie (las que tienen las 7 columnas separadas por tab).
  List<List<String>> cookieRows(String file) => file
      .split('\n')
      .map((l) => l.split('\t'))
      .where((c) => c.length == 7)
      .toList();

  group('header de Cookie', () {
    test('genera filas Netscape válidas para .instagram.com', () {
      final out = CookiesService.buildCookieFile(
        'sessionid=123%3Aabc; csrftoken=xyz',
      );

      expect(out.startsWith(magic), isTrue,
          reason: 'yt-dlp exige la línea mágica del formato');
      final rows = cookieRows(out);
      expect(rows.length, 2);

      final sid = rows.firstWhere((c) => c[5] == 'sessionid');
      expect(sid[0], '.instagram.com');
      expect(sid[1], 'TRUE'); // aplica a subdominios
      expect(sid[2], '/');
      expect(sid[3], 'FALSE'); // no exclusiva de https
      expect(int.parse(sid[4]), greaterThan(0)); // expiración numérica
      expect(sid[6], '123%3Aabc');

      expect(rows.any((c) => c[5] == 'csrftoken' && c[6] == 'xyz'), isTrue);
    });

    test('acepta el prefijo "Cookie:"', () {
      final out = CookiesService.buildCookieFile('Cookie: sessionid=abc123');
      final rows = cookieRows(out);
      expect(rows.length, 1);
      expect(rows.single[5], 'sessionid');
      expect(rows.single[6], 'abc123');
    });

    test('conserva los "=" internos del valor', () {
      final out = CookiesService.buildCookieFile('sessionid=abc==');
      expect(cookieRows(out).single[6], 'abc==');
    });

    test('valores separados por saltos de línea', () {
      final out = CookiesService.buildCookieFile(
        'sessionid=uno\ncsrftoken=dos',
      );
      expect(cookieRows(out).length, 2);
    });
  });

  group('valor suelto', () {
    test('un token largo sin nombre se toma como sessionid', () {
      const value = '7788990011%3Aabcdefghijklmnop%3A12';
      final out = CookiesService.buildCookieFile(value);
      final rows = cookieRows(out);
      expect(rows.single[5], 'sessionid');
      expect(rows.single[6], value);
    });

    test('texto corto sin "=" no produce cookies', () {
      expect(cookieRows(CookiesService.buildCookieFile('hola')).isEmpty, isTrue);
      expect(CookiesService.isUsable('hola'), isFalse);
    });
  });

  group('cookies.txt ya formateado', () {
    const netscape = '$magic\n'
        '#HttpOnly_.instagram.com\tTRUE\t/\tTRUE\t1790000000\tsessionid\tXYZ\n';

    test('se respeta tal cual', () {
      final out = CookiesService.buildCookieFile(netscape);
      expect(out.contains('\t1790000000\tsessionid\tXYZ'), isTrue);
      expect(cookieRows(out).single[0], '#HttpOnly_.instagram.com');
    });

    test('detecta el formato por sus columnas', () {
      const withoutMagic =
          '.instagram.com\tTRUE\t/\tFALSE\t1790000000\tsessionid\tABC\n';
      expect(CookiesService.looksLikeNetscape(withoutMagic), isTrue);
      // Sin la línea mágica yt-dlp aborta: se antepone.
      expect(
        CookiesService.buildCookieFile(withoutMagic).startsWith(magic),
        isTrue,
      );
    });

    test('un header no se confunde con Netscape', () {
      expect(
        CookiesService.looksLikeNetscape('sessionid=abc; csrftoken=xyz'),
        isFalse,
      );
    });
  });

  group('export JSON (extensiones)', () {
    // Formato real de Cookie-Editor: array de objetos con campos de Chrome.
    const cookieEditor = '''
[
  {"domain": ".instagram.com", "hostOnly": false, "httpOnly": true,
   "name": "sessionid", "path": "/", "sameSite": "no_restriction",
   "secure": true, "session": false, "storeId": "0",
   "value": "123%3Aabc", "expirationDate": 2000000000.5},
  {"domain": "www.instagram.com", "hostOnly": true, "httpOnly": false,
   "name": "csrftoken", "path": "/", "secure": true,
   "value": "XYZ", "expirationDate": 2000000111}
]''';

    test('convierte un array de Cookie-Editor', () {
      final out = CookiesService.buildCookieFile(cookieEditor);
      expect(out.startsWith(magic), isTrue);
      final rows = cookieRows(out);
      expect(rows.length, 2);

      final sid = rows.firstWhere((c) => c[5] == 'sessionid');
      expect(sid[0], '#HttpOnly_.instagram.com'); // httpOnly
      expect(sid[1], 'TRUE'); // hostOnly: false -> aplica a subdominios
      expect(sid[2], '/');
      expect(sid[3], 'TRUE'); // secure
      expect(sid[4], '2000000000'); // float -> segundos enteros
      expect(sid[6], '123%3Aabc');

      final csrf = rows.firstWhere((c) => c[5] == 'csrftoken');
      expect(csrf[0], 'www.instagram.com');
      expect(csrf[1], 'FALSE'); // hostOnly: true
      expect(csrf[4], '2000000111');
    });

    test('acepta el envoltorio {"cookies": [...]}', () {
      final out = CookiesService.buildCookieFile(
        '{"cookies":[{"name":"sessionid","value":"abc",'
        '"domain":".instagram.com","expirationDate":1790000000}]}',
      );
      expect(cookieRows(out).single[6], 'abc');
    });

    test('no manglea valores con ";" o "=" (JSON no es un header)', () {
      final out = CookiesService.buildCookieFile(
        '[{"name":"sessionid","value":"a;b=c","domain":".instagram.com"}]',
      );
      expect(cookieRows(out).single[6], 'a;b=c');
    });

    test('una fecha vencida se sustituye por una futura (no se descarta)', () {
      // 1000000000 = sep-2001: el jar de yt-dlp descartaría la cookie.
      final out = CookiesService.buildCookieFile(
        '[{"name":"sessionid","value":"abc","domain":".instagram.com",'
        '"expirationDate":1000000000}]',
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(int.parse(cookieRows(out).single[4]), greaterThan(now));
    });

    test('respeta una fecha futura del export', () {
      final out = CookiesService.buildCookieFile(
        '[{"name":"sessionid","value":"abc","domain":".instagram.com",'
        '"expirationDate":2000000000}]',
      );
      expect(cookieRows(out).single[4], '2000000000');
    });

    test('sin fecha usa una expiración futura válida', () {
      final out = CookiesService.buildCookieFile(
        '[{"name":"sessionid","value":"abc","domain":".instagram.com"}]',
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(int.parse(cookieRows(out).single[4]), greaterThan(now));
    });

    test('JSON sin cookies o inválido no produce archivo utilizable', () {
      expect(CookiesService.isUsable('[{"foo":1}]'), isFalse);
      expect(CookiesService.isUsable('{}'), isFalse);
      expect(CookiesService.isUsable('[no es json'), isFalse);
    });

    test('looksLikeJson distingue JSON de header y de Netscape', () {
      expect(CookiesService.looksLikeJson('  [{"name":"a"}]'), isTrue);
      expect(CookiesService.looksLikeJson('{"cookies":[]}'), isTrue);
      expect(CookiesService.looksLikeJson('sessionid=abc'), isFalse);
      expect(CookiesService.looksLikeJson(magic), isFalse);
    });
  });

  group('sessionid requerido', () {
    test('lo detecta en header y en cookies.txt', () {
      expect(CookiesService.containsSessionId('sessionid=abc'), isTrue);
      expect(CookiesService.containsSessionId('csrftoken=xyz'), isFalse);
      expect(
        CookiesService.containsSessionId(
          '.instagram.com\tTRUE\t/\tFALSE\t1790000000\tsessionid\tABC',
        ),
        isTrue,
      );
    });
  });

  group('entrada vacía', () {
    test('no genera cookies utilizables', () {
      expect(CookiesService.isUsable(''), isFalse);
      expect(CookiesService.isUsable('   '), isFalse);
      expect(cookieRows(CookiesService.buildCookieFile('')).isEmpty, isTrue);
    });
  });
}
