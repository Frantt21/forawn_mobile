// test/settings_playback_spacing_test.dart
//
// Regresión del hueco en la sección REPRODUCCIÓN: el toggle "Lyrics Sweep
// Effect" se retiró (commit c8de1bb) pero su contenedor quedó vacío, dejando
// un ListTile() sin contenido (~56px) más un SizedBox de sobra entre el
// crossfade y la opción de las teclas de volumen.
//
// El test mide la distancia real en pantalla entre el slider del crossfade y
// la opción de volumen, así que falla si el hueco vuelve.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:forawn/screens/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const saf = MethodChannel('forawn/saf');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // StorageBar pide el espacio libre por el canal SAF.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(saf, (call) async {
      if (call.method == 'getFreeSpace') return 1024 * 1024 * 1024;
      return null;
    });
    // _loadVersion usa PackageInfo.
    PackageInfo.setMockInitialValues(
      appName: 'Forawn',
      packageName: 'com.example.forawn_mobile',
      version: '1.0.4',
      buildNumber: '8',
      buildSignature: '',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(saf, null);
  });

  testWidgets('sin hueco entre crossfade y teclas de volumen', (tester) async {
    // Pantalla muy alta: así la sección de reproducción se construye entera
    // y las posiciones medidas son las reales.
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pump();

    // 1) No debe quedar ningún ListTile sin contenido (ese era el hueco).
    final emptyTiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((t) => t.title == null && t.subtitle == null)
        .length;
    expect(emptyTiles, 0, reason: 'hay ListTiles vacíos (huecos) en la lista');

    // 2) El hueco medido: del slider del crossfade a la opción de volumen.
    //    Con el ListTile vacío eran ~100px; con el espaciado normal, <50.
    final sliderBottom = tester.getBottomLeft(find.byType(Slider).first).dy;
    final volumeTop = tester
        .getTopLeft(find.text('volume_accessibility_title'))
        .dy;
    final gap = volumeTop - sliderBottom;
    debugPrint('[spacing] hueco crossfade -> teclas de volumen: ${gap}px');
    expect(gap, lessThanOrEqualTo(48), reason: 'hueco de ${gap}px');
  });
}
