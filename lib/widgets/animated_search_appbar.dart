import 'dart:ui';
import 'package:flutter/material.dart';

import 'app_search_field.dart';

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
            // Estilo unificado: widget compartido del input del video
            // downloader (píldora blanca 5% + botón circular incrustado).
            child: SizedBox(
              height: 48, // Altura fija para evitar saltos en el app bar
              child: AppSearchField(
                controller: _searchController,
                hintText: 'Buscar...',
                onChanged: (value) {
                  setState(() {});
                },
                onClear: () {
                  _searchController.clear();
                  setState(() {});
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
