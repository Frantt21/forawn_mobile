// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home.dart';
import 'screens/music_downloader_screen.dart';
import 'screens/images_ia_screen.dart';
import 'screens/translate_screen.dart';
import 'screens/qr_generator_screen.dart';
import 'screens/downloads_screen.dart';
import 'services/global_download_manager.dart';
import 'services/version_check_service.dart';
import 'services/language_service.dart';

import 'package:audio_service/audio_service.dart';
import 'services/audio_handler.dart';

import 'package:flutter_displaymode/flutter_displaymode.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optimizar tasa de refresco para pantallas de 90Hz/120Hz/144Hz
  try {
    // Obtener todos los modos disponibles
    final List<DisplayMode> modes = await FlutterDisplayMode.supported;

    // Encontrar el modo con mayor refresh rate
    DisplayMode? preferredMode;
    double maxRefreshRate = 0;

    for (var mode in modes) {
      if (mode.refreshRate > maxRefreshRate) {
        maxRefreshRate = mode.refreshRate;
        preferredMode = mode;
      }
    }

    if (preferredMode != null) {
      await FlutterDisplayMode.setPreferredMode(preferredMode);
      print(
        '[Main] Display mode set to: ${preferredMode.width}x${preferredMode.height} @ ${preferredMode.refreshRate}Hz',
      );
    } else {
      // Fallback al método anterior
      await FlutterDisplayMode.setHighRefreshRate();
      print('[Main] High refresh rate enabled (fallback)');
    }
  } catch (e) {
    print('[Main] Error setting high refresh rate: $e');
  }

  // Configuraciones adicionales de rendering para mejor performance
  // Habilitar edge-to-edge (pantalla completa)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Configurar barra de estado transparente
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize Audio Service for background playback notification
  try {
    await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.forawnt.app.audio',
        androidNotificationChannelName: 'Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher', // Icono de la app
      ),
    );
  } catch (e) {
    print('[Main] Error initializing AudioService: $e');
  }

  // Inicializar el servicio de idiomas
  try {
    await LanguageService().init();
  } catch (e) {
    print('[Main] Error initializing LanguageService: $e');
  }

  // Inicializar el gestor global de descargas
  await GlobalDownloadManager().initialize();

  // Verificar actualizaciones en segundo plano (sin bloquear el inicio)
  _checkForUpdatesInBackground();

  runApp(const ForawnApp());
}

/// Verificar actualizaciones en segundo plano
void _checkForUpdatesInBackground() async {
  try {
    // Esperar un poco para no afectar el tiempo de inicio
    await Future.delayed(const Duration(seconds: 2));

    // Solicitar permisos de notificación después de que la app esté lista
    try {
      await GlobalDownloadManager().requestNotificationPermissions();
    } catch (e) {
      print('[Main] Error requesting notification permissions: $e');
    }

    final result = await VersionCheckService.checkForUpdate();

    if (result.hasUpdate) {
      print('[Main] Nueva versión disponible: ${result.latestVersion}');
      // Aquí podrías mostrar una notificación o diálogo
      // Por ahora solo lo registramos en consola
    } else {
      print('[Main] App actualizada a la última versión');
    }
  } catch (e) {
    print('[Main] Error verificando actualizaciones: $e');
  }
}

/// Colores centralizados de la aplicación
class AppColors {
  // Colores principales
  static const Color background = Color.fromARGB(255, 34, 34, 34);
  static const Color accent = Colors.purpleAccent;
  static const Color text = Colors.white;

  // Colores de componentes
  static const Color cardBackground = Color.fromARGB(255, 34, 34, 34);
  static const Color appBarBackground = Color.fromARGB(255, 34, 34, 34);

  // Colores de navegación
  static const Color navBarBackground = Color.fromARGB(255, 34, 34, 34);
  static const Color navBarBorder = Color.fromARGB(255, 34, 34, 34);

  // Colores de acento adicionales
  static const Color yellow = Colors.yellowAccent;
  static const Color green = Colors.greenAccent;
  static const Color orange = Colors.orangeAccent;

  // Opacidades comunes
  static const double opacityHigh = 0.9;
  static const double opacityMedium = 0.7;
  static const double opacityLow = 0.5;
  static const double opacityVeryLow = 0.3;
}

class ForawnApp extends StatefulWidget {
  const ForawnApp({super.key});

  @override
  State<ForawnApp> createState() => _ForawnAppState();
}

class _ForawnAppState extends State<ForawnApp> {
  @override
  void initState() {
    super.initState();
    // Listen to language changes and rebuild the app
    LanguageService().addListener(_onLanguageChanged);
  }

  @override
  void dispose() {
    LanguageService().removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _onLanguageChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forawn Mobile',
      debugShowCheckedModeBanner: false,

      // Theme configuration
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.accent,
          surface: AppColors.background,
          onSurface: AppColors.text,
          onPrimary: const Color.fromARGB(255, 45, 45, 45),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: AppColors.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        textTheme: TextTheme(
          bodyLarge: TextStyle(color: AppColors.text),
          bodyMedium: TextStyle(color: AppColors.text),
          titleLarge: TextStyle(color: AppColors.text),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          ),
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardBackground,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      // Routing configuration
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/music-downloader': (context) => const MusicDownloaderScreen(),
        '/images-ia': (context) => const ImagesIAScreen(),
        '/translate': (context) => const TranslateScreen(),
        '/qr-generator': (context) => const QRGeneratorScreen(),
        '/downloads': (context) => const DownloadsScreen(),
      },

      // Handle unknown routes
      onUnknownRoute: (settings) {
        return MaterialPageRoute(builder: (context) => const HomeScreen());
      },
    );
  }
}
