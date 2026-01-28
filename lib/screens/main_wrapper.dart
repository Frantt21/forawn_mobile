import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/language_service.dart';
import '../services/music_history_service.dart';
import '../services/playlist_service.dart';
import '../services/local_music_state_service.dart';

import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart';
import '../services/widget_service.dart';

import 'home.dart';

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  @override
  State<MainWrapper> createState() => _MainWrapperState();
}

class _MainWrapperState extends State<MainWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  bool _initialized = false;
  double _loadingProgress = 0.0;

  @override
  void initState() {
    super.initState();

    // Controller used for timing the splash screen duration and fade out
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500), // Slightly faster fade
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.8, 1.0, curve: Curves.easeOut),
      ),
    );

    // Start loading data
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // 1. Language Service (Crucial for UI) - Fast init
      setState(() => _loadingProgress = 0.1);

      try {
        await LanguageService().init();
      } catch (e) {
        print("[MainWrapper] LanguageService Error: $e");
      }

      setState(() => _loadingProgress = 0.3);

      // 2. Heavy Services - Parallel Initialization
      // We group independent services to run concurrently in background
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

      // OPTIMIZATION: Do NOT await for these services. Let them run in background.
      servicesFuture.ignore(); // Fire and forget

      setState(() => _loadingProgress = 0.9);

      // Minimum splash duration for branding
      await Future.delayed(const Duration(seconds: 2));

      setState(() => _loadingProgress = 1.0);

      // Trigger fade out
      await _animationController.forward().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
        }
      });
    } catch (e) {
      print("[MainWrapper] Initialization Error: $e");
      // Force proceed
      if (mounted) {
        setState(() => _initialized = true);
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
      print('[MainWrapper] AudioService Init Error: $e');
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. The actual Home Screen (always built behind, or built when ready)
        // Building it behind allows it to be ready when we fade out splash
        const HomeScreen(),

        // 2. The Splash Overlay
        if (!_initialized)
          IgnorePointer(
            ignoring:
                _animationController.value >
                0.9, // Allow interaction once faded
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Scaffold(
                backgroundColor: const Color(0xFF121212),
                body: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Animated Logo
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
              ),
            ),
          ),
      ],
    );
  }
}
