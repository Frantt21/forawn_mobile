// lib/main.dart
import 'package:flutter/material.dart';
import 'screens/home.dart';
import 'screens/music_downloader_screen.dart';
import 'screens/images_ia_screen.dart';
import 'screens/translate_screen.dart';
import 'screens/qr_generator_screen.dart';
import 'screens/downloads_screen.dart';
import 'services/global_download_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar el gestor global de descargas
  await GlobalDownloadManager().initialize();
  await GlobalDownloadManager().requestNotificationPermissions();

  runApp(const ForawnApp());
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

class ForawnApp extends StatelessWidget {
  const ForawnApp({super.key});

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
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.appBarBackground,
          elevation: 0,
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
