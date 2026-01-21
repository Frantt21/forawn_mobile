import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/music_history_service.dart';
import '../services/playlist_service.dart';
import '../services/local_music_state_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  String _loadingStatus = ""; // To show what's loading

  @override
  void initState() {
    super.initState();

    // Animation setup related to the logo
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _animationController.forward();

    // Start loading data
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // 1. Language Service (Crucial for UI)
      // Already initialized in main, but ensuring readiness
      setState(() => _loadingStatus = "Loading Settings...");
      await Future.delayed(
        const Duration(milliseconds: 300),
      ); // Minimal delay for visual

      // 2. Music History (Heavy database op)
      setState(() => _loadingStatus = "Loading History...");
      await MusicHistoryService().init();

      // 3. Playlists (Database op)
      setState(() => _loadingStatus = "Loading Playlists...");
      await PlaylistService().init();

      // 4. Local Music State (Pre-fetch if possible)
      // We init the service (which might load last folder path from prefs)
      setState(() => _loadingStatus = "Initializing Library...");
      await LocalMusicStateService().init();

      // Wait for animation to finish if it hasn't
      if (_animationController.isAnimating) {
        // Wait for the remaining time of the animation manually
        // or just let it finish.
        // Since we don't have the TickerFuture stored, we can calculate remaining time
        // or just wait a fixed amount that is safe, or rely on listeners.
        // Simplest fix:
        final duration = _animationController.duration ?? Duration.zero;
        final elapsed =
            _animationController.lastElapsedDuration ?? Duration.zero;
        final remaining = duration - elapsed;
        if (remaining > Duration.zero) {
          await Future.delayed(remaining);
        }
      }

      // Small extra pause for smoothness
      await Future.delayed(const Duration(milliseconds: 500));

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
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Opacity(
                    opacity: _fadeAnimation.value,
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.purpleAccent.withOpacity(0.5),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                      // Replace with your actual app logo asset if available
                      // displaying an icon for now as placeholder
                      child: const Center(
                        child: Icon(
                          Icons.music_note_rounded,
                          size: 80,
                          color: Colors.purpleAccent,
                        ),
                      ),
                      // child: Image.asset('assets/icon/icon.png'), // Use this if you have an asset
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 50),

            // App Name
            FadeTransition(
              opacity: _fadeAnimation,
              child: const Text(
                "FORAWN",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
              ),
            ),

            const SizedBox(height: 30),

            // Loading Indicator & Text
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                color: Colors.purpleAccent.withOpacity(0.7),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _loadingStatus,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
