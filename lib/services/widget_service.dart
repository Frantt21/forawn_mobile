import 'package:audio_service/audio_service.dart';
import 'package:home_widget/home_widget.dart';
import '../models/song.dart';
import '../services/audio_player_service.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? data) async {
  if (data?.host == 'play') {
    print('Widget: Play');
    // We can't easily access the existing AudioPlayerService instance here freely
    // because this is a background isolate.
    // However, AudioService (the plugin) sends messages to the Android Service.
    // This assumes the Android Service is running.
    await AudioService.play();
  } else if (data?.host == 'pause') {
    print('Widget: Pause');
    await AudioService.pause();
  } else if (data?.host == 'next') {
    print('Widget: Next');
    await AudioService.skipToNext();
  } else if (data?.host == 'prev') {
    print('Widget: Prev');
    await AudioService.skipToPrevious();
  }
}

class WidgetService {
  static const String _widgetName = 'MusicWidgetProvider';
  // static const String _groupId = 'group.music_widget';

  static Future<void> initialize() async {
    await HomeWidget.registerBackgroundCallback(backgroundCallback);
  }

  static Future<void> updateWidget({
    required Song? song,
    required bool isPlaying,
  }) async {
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

    // Save Artwork Path
    // Ensure we passed a valid file path that the widget can read
    if (song?.artworkPath != null) {
      await HomeWidget.saveWidgetData<String>(
        'artwork_path',
        song!.artworkPath,
      );
    } else {
      // Clear specific key or handle in Kotlin
      await HomeWidget.saveWidgetData<String>('artwork_path', null);
    }

    // Save Dominant Color
    await HomeWidget.saveWidgetData<int>(
      'dominantColor',
      song?.dominantColor ?? 0xFF212121,
    );

    // Trigger Update
    await HomeWidget.updateWidget(name: _widgetName, androidName: _widgetName);
  }
}
