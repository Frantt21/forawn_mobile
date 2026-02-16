import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter/material.dart';
import '../models/song.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? data) async {
  if (data?.host == 'play') {
    await AudioService.play();
  } else if (data?.host == 'pause') {
    await AudioService.pause();
  } else if (data?.host == 'next') {
    await AudioService.skipToNext();
  } else if (data?.host == 'prev') {
    await AudioService.skipToPrevious();
  } else if (data?.host == 'favorite') {
    print('Widget: Favorite Toggle');
    // Send custom action to handler
    await AudioService.customAction('toggleFavorite', {});
  }
}

class WidgetService {
  static const String _widgetName = 'MusicWidgetProvider';
  static Timer? _debounce;

  static Future<void> initialize() async {
    await HomeWidget.registerBackgroundCallback(backgroundCallback);
  }

  static Future<void> updateWidget({
    required Song? song,
    required bool isPlaying,
    required bool isFavorite,
  }) async {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      // Save Data
      await HomeWidget.saveWidgetData<String>(
        'title',
        song?.title ?? 'Forawn Music',
      );
      await HomeWidget.saveWidgetData<String>(
        'artist',
        song?.artist ?? 'Tap to play',
      );
      await HomeWidget.saveWidgetData<bool>('isPlaying', isPlaying);
      await HomeWidget.saveWidgetData<bool>('isFavorite', isFavorite);

      // Color Calculation
      final dominantColorValue = song?.dominantColor ?? 0xFF212121;
      final dominantColor = Color(dominantColorValue);
      final brightness = ThemeData.estimateBrightnessForColor(dominantColor);
      final isDark = brightness == Brightness.dark;

      await HomeWidget.saveWidgetData<bool>('isDark', isDark);
      await HomeWidget.saveWidgetData<int>('dominantColor', dominantColorValue);

      // Save Artwork Path
      if (song?.artworkPath != null) {
        await HomeWidget.saveWidgetData<String>(
          'artwork_path',
          song!.artworkPath,
        );
      } else {
        await HomeWidget.saveWidgetData<String>('artwork_path', null);
      }

      // Trigger Update
      await HomeWidget.updateWidget(name: _widgetName, androidName: _widgetName);
    });
  }
}
