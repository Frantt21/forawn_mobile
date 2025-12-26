import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:io';

/// Widget reutilizable para mostrar artwork de canciones o playlists
///
/// Soporta:
/// - Uint8List (artwork embebido en memoria)
/// - File path (imagen local)
/// - Network URL (imagen remota)
/// - Placeholder cuando no hay artwork
class ArtworkContainer extends StatelessWidget {
  /// Datos de artwork en bytes (para canciones)
  final Uint8List? artworkData;

  /// Ruta de archivo o URL (para playlists)
  final String? imagePath;

  /// Tamaño del contenedor (ancho y alto)
  /// Si es null, el contenedor se expandirá para llenar el espacio disponible
  final double? size;

  /// Radio del borde redondeado
  final double borderRadius;

  /// Color de fondo cuando no hay artwork
  final Color? backgroundColor;

  /// Icono a mostrar cuando no hay artwork
  final IconData placeholderIcon;

  /// Color del icono placeholder
  final Color? placeholderIconColor;

  /// Si debe mostrar sombra
  final bool showShadow;

  const ArtworkContainer({
    super.key,
    this.artworkData,
    this.imagePath,
    this.size,
    this.borderRadius = 4,
    this.backgroundColor,
    this.placeholderIcon = Icons.music_note,
    this.placeholderIconColor,
    this.showShadow = false,
  });

  /// Factory constructor para canciones (usa artworkData)
  factory ArtworkContainer.song({
    Key? key,
    required Uint8List? artworkData,
    double size = 48,
    double borderRadius = 4,
    bool showShadow = false,
    Color? backgroundColor,
    IconData placeholderIcon = Icons.music_note,
    Color? placeholderIconColor,
  }) {
    return ArtworkContainer(
      key: key,
      artworkData: artworkData,
      size: size,
      borderRadius: borderRadius,
      showShadow: showShadow,
      backgroundColor: backgroundColor,
      placeholderIcon: placeholderIcon,
      placeholderIconColor: placeholderIconColor,
    );
  }

  /// Factory constructor para playlists (usa imagePath)
  factory ArtworkContainer.playlist({
    Key? key,
    required String? imagePath,
    double size = 48,
    double borderRadius = 4,
    bool showShadow = false,
    Color? backgroundColor,
    IconData placeholderIcon = Icons.music_note,
    Color? placeholderIconColor,
  }) {
    return ArtworkContainer(
      key: key,
      imagePath: imagePath,
      size: size,
      borderRadius: borderRadius,
      showShadow: showShadow,
      backgroundColor: backgroundColor,
      placeholderIcon: placeholderIcon,
      placeholderIconColor: placeholderIconColor,
    );
  }

  ImageProvider? _getImageProvider() {
    // Prioridad 1: artworkData (bytes en memoria)
    if (artworkData != null) {
      return MemoryImage(artworkData!);
    }

    // Prioridad 2: imagePath (archivo o URL)
    if (imagePath != null && imagePath!.isNotEmpty) {
      if (imagePath!.startsWith('http://') ||
          imagePath!.startsWith('https://')) {
        return NetworkImage(imagePath!);
      } else if (File(imagePath!).existsSync()) {
        return FileImage(File(imagePath!));
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ?? Colors.grey[800];
    final iconColor = placeholderIconColor ?? Colors.white54;

    // OPTIMIZACIÓN CRÍTICA: Para artworkData, usar Image.memory con cache
    if (artworkData != null) {
      final effectiveSize = size ?? 100.0;

      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: showShadow
              ? [
                  const BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.memory(
            artworkData!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            // ✅ CRÍTICO: Pre-decodifica al tamaño correcto en UI thread
            cacheWidth: effectiveSize.toInt(),
            cacheHeight: effectiveSize.toInt(),
            gaplessPlayback: true, // Suaviza transiciones
            errorBuilder: (context, error, stackTrace) {
              return Icon(
                placeholderIcon,
                color: iconColor,
                size: effectiveSize * 0.5,
              );
            },
          ),
        ),
      );
    }

    // Para imagePath, usar el código existente con DecorationImage
    final imageProvider = _getImageProvider();

    // Si size es null, usar LayoutBuilder para obtener constraints
    if (size == null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Usar las constraints disponibles
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : null;
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : null;

          // Calcular el tamaño del icono basado en el espacio disponible
          final iconSize = (width ?? height ?? 100.0) * 0.5;

          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(borderRadius),
              image: imageProvider != null
                  ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
                  : null,
              boxShadow: showShadow
                  ? [
                      const BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: imageProvider == null
                ? Icon(placeholderIcon, color: iconColor, size: iconSize)
                : null,
          );
        },
      );
    }

    // Si size está definido, usar tamaño fijo
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        image: imageProvider != null
            ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
            : null,
        boxShadow: showShadow
            ? [
                const BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: imageProvider == null
          ? Icon(placeholderIcon, color: iconColor, size: size! * 0.5)
          : null,
    );
  }
}
