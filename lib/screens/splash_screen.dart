import 'package:flutter/material.dart';

import '../services/language_service.dart';
import '../services/music_history_service.dart';
import '../services/playlist_service.dart';
import '../services/local_music_state_service.dart';

import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart';
import '../services/widget_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  double _loadingProgress = 0.0;
  @override
  void initState() {
    super.initState();

    // Controller used for timing the splash screen duration
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _animationController.forward();

    // Start loading data
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // 1. Language Service (Crucial for UI) - Fast init
      setState(() => _loadingProgress = 0.1);

      // Initialize Language Service FIRST to ensure strings are available
      // Note: In main() we removed it, so we must be sure to init it here.
      // Assuming LanguageService().init() is idempotent or safe to call.
      // In the previous code, LanguageService was initialized in main. Now here.
      // But wait! LanguageService().init() is actually needed for the App to rebuild with correct locale?
      // Since SplashScreen is already built, it might be fine, effectively 'en' default.
      // We will init it here.
      try {
        await LanguageService().init();
      } catch (e) {
        print("[SplashScreen] LanguageService Error: $e");
      }

      setState(() => _loadingProgress = 0.3);

      // 2. Heavy Services - Parallel Initialization
      // We group independent services to run concurrently
      final servicesFuture = Future.wait([
        // Audio Service
        _initAudioService(),

        // Database & State Services
        MusicHistoryService().init(),
        PlaylistService().init(),
        LocalMusicStateService().init(),

        // Background Managers
        WidgetService.initialize(),
      ]);

      // Update progress while waiting (simulated for UX)
      // In a real scenario, we could attach listeners to each future, but simple await is safer.
      // Update progress while waiting (simulated for UX)
      // In a real scenario, we could attach listeners to each future, but simple await is safer.
      // OPTIMIZATION: Do NOT await for these services. Let them run in background.
      // The 2s splash animation provides a sufficient buffer for critical inits (like AudioService).
      // If they take longer, the UI (Home/Library) is reactive and will update when ready.
      servicesFuture.ignore(); // Fire and forget

      setState(() => _loadingProgress = 0.9);

      // Wait for animation to finish if it hasn't
      if (_animationController.isAnimating) {
        final duration = _animationController.duration ?? Duration.zero;
        final elapsed =
            _animationController.lastElapsedDuration ?? Duration.zero;
        final remaining = duration - elapsed;
        if (remaining > Duration.zero) {
          await Future.delayed(remaining);
        }
      }

      // Small extra pause for smoothness
      setState(() => _loadingProgress = 1.0);
      await Future.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/');
      }
    } catch (e) {
      print("[SplashScreen] Initialization Error: $e");
      // Proceed even on error to let user retry or see main screen
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/');
      }
    }
  }

  Future<void> _initAudioService() async {
    try {
      await AudioService.init(
        builder: () => MyAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.forawnt.app.audio',
          androidNotificationChannelName: 'Music Playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'drawable/ic_stat_logo',
        ),
      );
    } catch (e) {
      print('[SplashScreen] AudioService Init Error: $e');
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(
        0xFF121212,
      ), // Dark background matches app theme
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animated Logo
            // Logo without animation or shadow
            SizedBox(
              width: 150,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 30),

            // App Name
            const Text(
              "Forawn",
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 30),

            // Loading Indicator (Barra)
            SizedBox(
              width: 150,
              child: LinearProgressIndicator(
                value: _loadingProgress,
                color: Colors.purpleAccent,
                backgroundColor: Colors.white10,
                borderRadius: BorderRadius.circular(10),
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
