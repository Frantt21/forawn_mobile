import 'dart:io';
import 'package:flutter/material.dart';

class ArtworkWidget extends StatelessWidget {
  final String? artworkPath;
  final String? artworkUri;
  final double size;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final int? dominantColor;

  const ArtworkWidget({
    super.key,
    this.artworkPath,
    this.artworkUri,
    this.size = 50,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.dominantColor,
  });

  double _calculateRadius(double w, double h) {
    double minDim;
    if (w.isFinite && h.isFinite) {
      minDim = w < h ? w : h;
    } else if (w.isFinite) {
      minDim = w;
    } else if (h.isFinite) {
      minDim = h;
    } else {
      // If both are infinite, fall back to the explicit size param if it's usable,
      // or assume a large size since it's filling the screen.
      minDim = size > 0 ? size : 300.0;
    }

    // Proportional radius mapping
    if (minDim >= 200) return 24.0;
    if (minDim >= 100) return 12.0;
    return 8.0;
  }

  @override
  Widget build(BuildContext context) {
    final w = width ?? size;
    final h = height ?? size;

    final computedRadius = _calculateRadius(w, h);
    final radius = borderRadius ?? BorderRadius.circular(computedRadius);

    Widget imageContent;

    if (artworkPath != null && artworkPath!.isNotEmpty) {
      final file = File(artworkPath!);
      if (file.existsSync()) {
        imageContent = Image.file(
          file,
          width: w,
          height: h,
          fit: fit,
          cacheWidth: (() {
            if (w.isFinite && w > 0) {
              try {
                return (w * MediaQuery.of(context).devicePixelRatio).toInt();
              } catch (_) {}
            }
            return null;
          })(),
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholder(w, h),
        );
      } else {
        imageContent = _buildPlaceholder(w, h);
      }
    } else {
      imageContent = _buildPlaceholder(w, h);
    }

    return ClipRRect(borderRadius: radius, child: imageContent);
  }

  Widget _buildPlaceholder(double w, double h) {
    if (placeholder != null) {
      return SizedBox(width: w, height: h, child: placeholder);
    }

    // Default placeholder with dominant color if available
    final color = dominantColor != null
        ? Color(dominantColor!)
        : Colors.grey[900];

    double iconSize = 24;
    if (w.isFinite && h.isFinite) {
      iconSize = (w < h ? w : h) * 0.5;
    } else if (w.isFinite) {
      iconSize = w * 0.5;
    } else if (h.isFinite) {
      iconSize = h * 0.5;
    }

    return Container(
      width: w,
      height: h,
      color: color,
      child: Icon(Icons.music_note, color: Colors.white24, size: iconSize),
    );
  }
}
