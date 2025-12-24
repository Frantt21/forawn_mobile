import 'dart:ui';
import 'package:flutter/material.dart';

class AnimatedSearchAppBar extends StatefulWidget
    implements PreferredSizeWidget {
  final String title;
  final bool isScrolled;
  final Widget? leading;
  final List<Widget>? actions;
  final Function(String)? onSearch;
  final bool showSearch;

  const AnimatedSearchAppBar({
    super.key,
    required this.title,
    this.isScrolled = false,
    this.leading,
    this.actions,
    this.onSearch,
    this.showSearch = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<AnimatedSearchAppBar> createState() => _AnimatedSearchAppBarState();
}

class _AnimatedSearchAppBarState extends State<AnimatedSearchAppBar>
    with SingleTickerProviderStateMixin {
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _searchController.addListener(() {
      if (widget.onSearch != null) {
        widget.onSearch!(_searchController.text);
      }
    });
  }

  @override
  void didUpdateWidget(AnimatedSearchAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Close search when showSearch becomes false (screen changed)
    if (!widget.showSearch && _isSearching) {
      _toggleSearch();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (_isSearching) {
        _animationController.forward();
        Future.delayed(const Duration(milliseconds: 100), () {
          _searchFocusNode.requestFocus();
        });
      } else {
        _animationController.reverse();
        _searchController.clear();
        _searchFocusNode.unfocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AppBar(
            title: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: _isSearching
                  ? _buildSearchField()
                  : Align(
                      key: const ValueKey('title'),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
            backgroundColor: Colors
                .transparent, // Siempre transparente para coincidir con Home
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            leading: widget.leading,
            actions: [
              if (widget.showSearch)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return ScaleTransition(scale: animation, child: child);
                      },
                  child: IconButton(
                    key: ValueKey(_isSearching),
                    icon: Icon(_isSearching ? Icons.close : Icons.search),
                    onPressed: _toggleSearch,
                  ),
                ),
              if (!_isSearching && widget.actions != null) ...widget.actions!,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return AnimatedBuilder(
      key: const ValueKey('search'),
      animation: _animationController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(
            (1 - _fadeAnimation.value) * 300,
            0,
          ), // Slide from right
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: Card(
              color: const Color(0xFF1C1C1E),
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                height: 40, // Height fija para evitar saltos
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height:
                        1.0, // Altura de línea estricta para centrado perfecto
                  ),
                  onChanged: (value) {
                    setState(() {});
                  },
                  decoration: InputDecoration(
                    isCollapsed: true, // Desactivar defaults
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical:
                          11, // (40px - 16px) / 2 = 12px (aprox 11 para compensar baseline)
                    ),
                    hintText: 'Buscar...',
                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 16,
                      height:
                          1.0, // Coincidir exactamente con el estilo del texto
                    ),
                    border: InputBorder.none,
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              color: Colors.white70,
                              size: 20,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            // Asegura que el icono no rompa el centrado
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            iconSize: 20,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
