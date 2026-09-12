// lib/widgets/app_search_field.dart
//
// Campo de búsqueda unificado de forawn_mobile: réplica exacta del input del
// video_downloader_screen (píldora blanca 5%, radio 16, padding interior 8 y
// botón de búsqueda/limpiar circular blanco 20% incrustado a la derecha).
//
// Todos los inputs de búsqueda de la app usan este widget para que se vean
// y se comporten igual en toda la app.

import 'package:flutter/material.dart';

class AppSearchField extends StatelessWidget {
  /// Controller externo (el estado de búsqueda vive en el caller).
  final TextEditingController controller;

  /// Texto de ayuda (hint).
  final String hintText;

  /// Callback al pulsar el botón de búsqueda o enviar con el teclado.
  final VoidCallback? onSearch;

  /// Callback en cada cambio de texto (opcional; para filtros en vivo).
  final ValueChanged<String>? onChanged;

  /// Callback al pulsar la X de limpiar (opcional; por defecto limpia y
  /// notifica con onChanged('')).
  final VoidCallback? onClear;

  /// Muestra spinner en el botón en lugar del icono de búsqueda.
  final bool isLoading;

  /// Color del cursor (por defecto el acento morado de la app).
  final Color? cursorColor;

  /// Acción del teclado (por defecto "search").
  final TextInputAction textInputAction;

  const AppSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onSearch,
    this.onChanged,
    this.onClear,
    this.isLoading = false,
    this.cursorColor,
    this.textInputAction = TextInputAction.search,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasText = controller.text.isNotEmpty;
    return Container(
      // Píldora del input del video downloader: fondo blanco 5%, radio 16,
      // padding interior 8 que deja "flotar" el botón circular dentro.
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              cursorColor: cursorColor ?? Colors.purpleAccent,
              onChanged: onChanged,
              textInputAction: textInputAction,
              onSubmitted: (_) => onSearch?.call(),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 15,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Botón circular blanco 20% incrustado (idéntico al del video
          // downloader): búsqueda con spinner mientras carga, X cuando
          // hay texto y no está cargando.
          IconButton(
            icon: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : hasText && onSearch == null
                ? const Icon(Icons.close, color: Colors.white, size: 22)
                : const Icon(Icons.search, color: Colors.white),
            onPressed: isLoading
                ? null
                : hasText && onSearch == null
                ? (onClear ??
                      () {
                        controller.clear();
                        onChanged?.call('');
                      })
                : onSearch,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.2),
              padding: const EdgeInsets.all(8),
            ),
          ),
        ],
      ),
    );
  }
}
