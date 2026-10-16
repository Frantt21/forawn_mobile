// test/video_downloader_folder_test.dart
//
// Verifica el selector de carpeta del descargador de video: al tocar el
// icono se abre el selector SAF y la carpeta elegida queda en la preferencia
// COMPARTIDA 'saf_tree_uri' (la misma que usan música y QR), que es la que
// viaja como `treeUri` en cada descarga. No hay plugins reales: el canal SAF
// 'forawn/saf' y SharedPreferences están mockeados.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:forawn/screens/video_downloader_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('forawn/saf');
  const fakeTreeUri =
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
  final calls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickDirectory') return fakeTreeUri;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Monta la pantalla y deja resolver la carga inicial del treeUri.
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: VideoDownloaderScreen()));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('muestra el botón de carpeta', (tester) async {
    await pumpScreen(tester);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
  });

  testWidgets('tocar el icono abre el selector SAF y guarda la carpeta',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(calls, contains('pickDirectory'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('saf_tree_uri'), fakeTreeUri);

    // Estado coherente: icono acentuado + aviso al usuario.
    final icon = tester.widget<Icon>(find.byIcon(Icons.folder_open));
    expect(icon.color, Colors.purpleAccent);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('mantener pulsado muestra la carpeta ya guardada',
      (tester) async {
    // Se escribe en la MISMA instancia mock que usa la pantalla (setMockInitial
    // Values solo afecta a instancias nuevas y aquí ya hay una cacheada).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saf_tree_uri', fakeTreeUri);

    await pumpScreen(tester);
    // El icono ya debe salir marcado: la carpeta se cargó de la preferencia.
    expect(
      tester.widget<Icon>(find.byIcon(Icons.folder_open)).color,
      Colors.purpleAccent,
    );

    await tester.longPress(find.byIcon(Icons.folder_open));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(fakeTreeUri), findsOneWidget);
  });
}
