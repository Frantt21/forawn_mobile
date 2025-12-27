// lib/screens/home.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_screen.dart';
import 'notifications_screen.dart';
import 'local_music_screen.dart';
import '../services/language_service.dart';
import '../services/saf_helper.dart';
import '../widgets/animated_search_appbar.dart';
import '../widgets/assistant_chat_dialog.dart';

/// Servicio persistente para pantallas recientes
class RecentScreensService {
  static final RecentScreensService _instance =
      RecentScreensService._internal();
  factory RecentScreensService() => _instance;
  RecentScreensService._internal();

  static const String _prefsKey = 'recent_screens_v1';
  final List<RecentScreen> _recentScreens = [];
  bool _initialized = false;

  List<RecentScreen> get recentScreens => List.unmodifiable(_recentScreens);

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> decoded = json.decode(raw);
        _recentScreens.clear();
        for (final item in decoded) {
          try {
            _recentScreens.add(
              RecentScreen.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      // Ignorar errores de lectura; empezamos vacíos
    } finally {
      _initialized = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = json.encode(
        _recentScreens.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_prefsKey, encoded);
    } catch (e) {
      // No bloquear la app por errores de persistencia
    }
  }

  Future<void> addScreen(
    String title,
    String route,
    IconData icon,
    Color color,
  ) async {
    _recentScreens.removeWhere((screen) => screen.route == route);

    _recentScreens.insert(
      0,
      RecentScreen(
        title: title,
        route: route,
        iconCodePoint: icon.codePoint,
        iconFontFamily: icon.fontFamily,
        iconFontPackage: icon.fontPackage,
        colorValue: color.value,
        visitedAt: DateTime.now(),
      ),
    );

    if (_recentScreens.length > 10) {
      _recentScreens.removeLast();
    }

    await _persist();
  }

  Future<void> clearHistory() async {
    _recentScreens.clear();
    await _persist();
  }
}

class RecentScreen {
  final String title;
  final String route;
  final int iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final int colorValue;
  final DateTime visitedAt;

  RecentScreen({
    required this.title,
    required this.route,
    required this.iconCodePoint,
    required this.iconFontFamily,
    required this.iconFontPackage,
    required this.colorValue,
    required this.visitedAt,
  });

  IconData get icon => IconData(
    iconCodePoint,
    fontFamily: iconFontFamily,
    fontPackage: iconFontPackage,
  );
  Color get color => Color(colorValue);

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'route': route,
      'iconCodePoint': iconCodePoint,
      'iconFontFamily': iconFontFamily,
      'iconFontPackage': iconFontPackage,
      'colorValue': colorValue,
      'visitedAt': visitedAt.toIso8601String(),
    };
  }

  factory RecentScreen.fromJson(Map<String, dynamic> json) {
    return RecentScreen(
      title: json['title'] ?? '',
      route: json['route'] ?? '',
      iconCodePoint: json['iconCodePoint'] ?? 0,
      iconFontFamily: json['iconFontFamily'],
      iconFontPackage: json['iconFontPackage'],
      colorValue: json['colorValue'] ?? 0xFF000000,
      visitedAt: DateTime.tryParse(json['visitedAt'] ?? '') ?? DateTime.now(),
    );
  }

  String get timeAgo {
    final difference = DateTime.now().difference(visitedAt);
    final lang = LanguageService();

    if (difference.inMinutes < 1) return lang.getText('visited_now');
    if (difference.inMinutes < 60) {
      return lang.getText('visited_min_ago', {
        'min': '${difference.inMinutes}',
      });
    }
    if (difference.inHours < 24) {
      return lang.getText('visited_hours_ago', {
        'hours': '${difference.inHours}',
      });
    }
    if (difference.inDays == 1) return lang.getText('visited_yesterday');
    return lang.getText('visited_days_ago', {'days': '${difference.inDays}'});
  }
}

/// Pantalla principal con Bottom Navigation
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RecentScreensService _recentScreensService = RecentScreensService();
  final GlobalKey<NotificationsScreenState> _notificationsKey =
      GlobalKey<NotificationsScreenState>();
  int _selectedIndex = 0;
  bool _isScrolled = false;
  bool _isKeyboardVisible = false;
  String _searchQuery = '';
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _selectedIndex);
    _initServices();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _initServices() async {
    await _recentScreensService.init();
    if (mounted) setState(() {}); // refrescar UI con datos cargados
  }

  Future<void> _navigateToScreen(
    String route,
    String title,
    IconData icon,
    Color color,
  ) async {
    await _recentScreensService.addScreen(title, route, icon, color);
    Navigator.pushNamed(context, route).then((_) {
      setState(() {}); // refrescar recientes al volver
    });
  }

  String _getTranslatedTitle(String title) {
    // Map of saved titles to translation keys
    final titleMap = {
      'Descargador de Música': 'music_downloader',
      'Music Downloader': 'music_downloader',
      'Generador de Imágenes': 'image_generator',
      'Image Generator': 'image_generator',
      'Traductor': 'translator',
      'Translator': 'translator',
      'Generador QR': 'qr_generator',
      'QR Generator': 'qr_generator',
    };

    final key = titleMap[title];
    return key != null ? LanguageService().getText(key) : title;
  }

  void _onBottomNavTap(int index) {
    setState(() {
      _selectedIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  Widget _buildHomeContent(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final textColor = theme.colorScheme.onSurface;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(
        left: 16.0,
        right: 16.0,
        top: 16.0,
        bottom: 100.0, // Espacio interno para el Nav Bar flotante
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time and Date Header (sin card)
          const TimeHeader(),

          const SizedBox(height: 24),

          // Navigation Cards
          Text(
            LanguageService().getText('quick_access'),
            style: TextStyle(
              color: textColor,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NavigationCard(
                  icon: Icons.music_note,
                  title: LanguageService().getText('music_downloader'),
                  color: accentColor,
                  onTap: () => _navigateToScreen(
                    '/music-downloader',
                    LanguageService().getText('music_downloader'),
                    Icons.music_note,
                    accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NavigationCard(
                  icon: Icons.image,
                  title: LanguageService().getText('image_generator'),
                  color: Colors.yellowAccent,
                  onTap: () => _navigateToScreen(
                    '/images-ia',
                    LanguageService().getText('image_generator'),
                    Icons.image,
                    Colors.yellowAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NavigationCard(
                  icon: Icons.translate,
                  title: LanguageService().getText('translator'),
                  color: Colors.greenAccent,
                  onTap: () => _navigateToScreen(
                    '/translate',
                    LanguageService().getText('translator'),
                    Icons.translate,
                    Colors.greenAccent,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NavigationCard(
                  icon: Icons.qr_code,
                  title: LanguageService().getText('qr_generator'),
                  color: Colors.orangeAccent,
                  onTap: () => _navigateToScreen(
                    '/qr-generator',
                    LanguageService().getText('qr_generator'),
                    Icons.qr_code,
                    Colors.orangeAccent,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          // Recent Screens
          if (_recentScreensService.recentScreens.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  LanguageService().getText('recent_screens'),
                  style: TextStyle(
                    color: textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await _recentScreensService.clearHistory();
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          LanguageService().getText('history_cleared'),
                        ),
                      ),
                    );
                  },
                  child: Text(
                    LanguageService().getText('clear'),
                    style: TextStyle(color: accentColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                // Filter recent screens by search query
                final filteredScreens = _searchQuery.isEmpty
                    ? _recentScreensService.recentScreens
                    : _recentScreensService.recentScreens.where((screen) {
                        final title = _getTranslatedTitle(
                          screen.title,
                        ).toLowerCase();
                        return title.contains(_searchQuery);
                      }).toList();

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredScreens.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final screen = filteredScreens[index];

                    return Card(
                      color: const Color.fromARGB(255, 45, 45, 45),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Colors.white.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: screen.color.withOpacity(0.2),
                          child: Icon(
                            screen.icon,
                            color: screen.color,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          _getTranslatedTitle(screen.title),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          screen.timeAgo,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.5),
                        ),
                        onTap: () {
                          _navigateToScreen(
                            screen.route,
                            screen.title,
                            screen.icon,
                            screen.color,
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ] else ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  children: [
                    Icon(
                      Icons.history,
                      size: 64,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.3),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      LanguageService().getText('no_recent_screens'),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.5),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      LanguageService().getText('explore_options'),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.4),
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlaceholder(String title, IconData icon) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: textColor.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                color: textColor.withOpacity(0.9),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Esta pantalla aún no está disponible',
              style: TextStyle(color: textColor.withOpacity(0.6)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Widget bodyContent no longer used with PageView
    // switch replaced by PageView logic

    // Detectar si el teclado está visible
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    _isKeyboardVisible = keyboardHeight > 0;

    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AnimatedSearchAppBar(
        title: _selectedIndex == 1
            ? 'Local Music'
            : (_selectedIndex == 2
                  ? LanguageService().getText('notifications')
                  : (_selectedIndex == 3
                        ? LanguageService().getText('settings')
                        : LanguageService().getText('app_name'))),
        isScrolled: _isScrolled,
        showSearch: _selectedIndex == 1, // Solo en Local Music
        onSearch: (query) {
          setState(() {
            _searchQuery = query.toLowerCase();
          });
        },
        leading: null,
        actions: [
          if (_selectedIndex == 1)
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                final uri = await SafHelper.pickDirectory();
                if (uri != null) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('selected_music_folder', uri);
                  setState(() {});
                }
              },
              tooltip: 'Seleccionar Carpeta',
            ),
          if (_selectedIndex == 2 &&
              _notificationsKey.currentState?.hasNotifications == true)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: LanguageService().getText('clear_all'),
              onPressed: () {
                _notificationsKey.currentState?.clearAllFromAppBar();
              },
            ),
          // AI Assistant button (available on all screens)
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).primaryColor,
                    Theme.of(context).primaryColor.withOpacity(0.7),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.smart_toy_outlined,
                color: Colors.white,
                size: 20,
              ),
            ),
            tooltip: 'Asistente Musical',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => const AssistantChatDialog(
                  availableSongs:
                      [], // TODO: Pasar canciones de LocalMusicScreen
                ),
              );
            },
          ),
        ],
      ),
      body: Container(
        color: const Color.fromARGB(255, 34, 34, 34),
        child: Stack(
          children: [
            // Main content - full height, scrollable behind nav
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (ScrollNotification scrollInfo) {
                    // Detectar scroll en cualquier página para actualizar el AppBar
                    if (scrollInfo.depth == 0) {
                      if (scrollInfo.metrics.pixels > 10 && !_isScrolled) {
                        setState(() {
                          _isScrolled = true;
                        });
                      } else if (scrollInfo.metrics.pixels <= 10 &&
                          _isScrolled) {
                        setState(() {
                          _isScrolled = false;
                        });
                      }
                    }
                    return false;
                  },
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    physics: const BouncingScrollPhysics(),
                    children: [
                      RepaintBoundary(child: _buildHomeContent(context)),
                      RepaintBoundary(
                        child: LocalMusicScreen(searchQuery: _searchQuery),
                      ),

                      RepaintBoundary(
                        child: NotificationsScreen(key: _notificationsKey),
                      ),
                      const RepaintBoundary(child: SettingsScreen()),
                    ],
                  ),
                ),
              ),
            ),

            // Floating Navigation Bar (oculto en ForaAI y Local Music) con animación
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: AnimatedOpacity(
                opacity:
                    (!_isKeyboardVisible &&
                        _selectedIndex != 2 &&
                        _selectedIndex != 1)
                    ? 1.0
                    : 0.0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: AnimatedSlide(
                  offset:
                      (!_isKeyboardVisible &&
                          _selectedIndex != 2 &&
                          _selectedIndex != 1)
                      ? Offset.zero
                      : const Offset(0, 0.5),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: IgnorePointer(
                    ignoring:
                        _isKeyboardVisible ||
                        _selectedIndex == 2 ||
                        _selectedIndex == 1,
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
                                _buildNavItem(Icons.home, 0, accentColor),
                                _buildNavItem(
                                  Icons.library_music,
                                  1,
                                  accentColor,
                                ), // Local Music
                                _buildNavItem(
                                  Icons.notifications_outlined,
                                  2,
                                  accentColor,
                                ), // Notifications
                                _buildNavItem(
                                  Icons.settings,
                                  3,
                                  accentColor,
                                ), // Settings
                              ],
                            ),
                          ),
                        ),
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

  Widget _buildNavItem(IconData icon, int index, Color accentColor) {
    final isSelected = _selectedIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onBottomNavTap(index),
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

class _NavigationCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  const _NavigationCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color.fromARGB(255, 45, 45, 45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget que muestra la hora y saludo sin card, con fecha a la izquierda y hora a la derecha
class TimeHeader extends StatefulWidget {
  const TimeHeader({super.key});

  @override
  State<TimeHeader> createState() => _TimeHeaderState();
}

class _TimeHeaderState extends State<TimeHeader> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      setState(() {
        _now = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _greeting() {
    final hour = _now.hour;
    final lang = LanguageService();
    if (hour >= 5 && hour < 12) return lang.getText('good_morning');
    if (hour >= 12 && hour < 19) return lang.getText('good_afternoon');
    return lang.getText('good_evening');
  }

  IconData _greetingIcon() {
    final hour = _now.hour;
    if (hour >= 5 && hour < 12) return Icons.wb_sunny; // Morning
    if (hour >= 12 && hour < 19) return Icons.wb_sunny_outlined; // Afternoon
    return Icons.nightlight_round; // Night
  }

  Color _greetingIconColor() {
    final hour = _now.hour;
    if (hour >= 5 && hour < 12) {
      return Colors.orange; // Morning - vibrant orange
    }
    if (hour >= 12 && hour < 19) return Colors.amber; // Afternoon - warm amber
    return Colors.deepPurple.shade300; // Night - soft purple
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 45, 45, 45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Lado izquierdo: Saludo y hora
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Saludo con ícono
              Row(
                children: [
                  Icon(_greetingIcon(), size: 20, color: _greetingIconColor()),
                  const SizedBox(width: 8),
                  Text(
                    _greeting(),
                    style: TextStyle(
                      color: textColor.withOpacity(0.7),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Hora debajo del saludo
              Text(
                '${_formatTwoDigits(_now.hour)}:${_formatTwoDigits(_now.minute)}',
                style: TextStyle(
                  color: textColor,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
          // Lado derecho: Fecha (centrada verticalmente)
          Text(
            '${_weekdayName(_now.weekday)}\n${_now.day}/${_now.month}/${_now.year}',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: textColor.withOpacity(0.8),
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTwoDigits(int n) => n.toString().padLeft(2, '0');

  String _weekdayName(int wd) {
    final keys = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    return LanguageService().getText(keys[(wd - 1) % 7]);
  }
}
