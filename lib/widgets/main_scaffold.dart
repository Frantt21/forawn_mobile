import 'dart:ui';
import 'package:flutter/material.dart';

/// Scaffold wrapper con Bottom Navigation persistente
/// Usado en Local Music, Notifications y Settings
class MainScaffold extends StatelessWidget {
  final Widget child;
  final int currentIndex;
  final PreferredSizeWidget? appBar;

  const MainScaffold({
    super.key,
    required this.child,
    required this.currentIndex,
    this.appBar,
  });

  void _onNavTap(BuildContext context, int index) {
    // Si ya estamos en la pantalla, no hacer nada
    if (index == currentIndex) return;

    // Navegar usando pushReplacementNamed para destruir la pantalla anterior
    switch (index) {
      case 0:
        Navigator.pushReplacementNamed(context, '/');
        break;
      case 1:
        Navigator.pushReplacementNamed(context, '/local-music');
        break;
      case 2:
        Navigator.pushReplacementNamed(context, '/notifications');
        break;
      case 3:
        Navigator.pushReplacementNamed(context, '/settings');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: appBar,
      body: Container(
        color: const Color.fromARGB(255, 34, 34, 34),
        child: Stack(
          children: [
            // Content
            Positioned.fill(child: child),

            // Floating Navigation Bar
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(
                          255,
                          45,
                          45,
                          45,
                        ).withOpacity(0.7),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildNavItem(context, Icons.home, 0, accentColor),
                          _buildNavItem(
                            context,
                            Icons.library_music,
                            1,
                            accentColor,
                          ),
                          _buildNavItem(
                            context,
                            Icons.notifications_outlined,
                            2,
                            accentColor,
                          ),
                          _buildNavItem(
                            context,
                            Icons.settings,
                            3,
                            accentColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    int index,
    Color accentColor,
  ) {
    final isSelected = currentIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onNavTap(context, index),
        behavior: HitTestBehavior.opaque,
        child: UnconstrainedBox(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(
              horizontal: isSelected ? 20 : 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? accentColor.withOpacity(0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              icon,
              size: isSelected ? 28 : 24,
              color: isSelected
                  ? accentColor
                  : Theme.of(context).iconTheme.color?.withOpacity(0.6),
            ),
          ),
        ),
      ),
    );
  }
}
