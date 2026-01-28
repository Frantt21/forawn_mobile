package com.example.forawn_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class MusicWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: android.content.SharedPreferences) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.music_widget).apply {
                // Open App on Background Click
                val pendingIntent = Intent(context, MainActivity::class.java).let { intent ->
                    PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                }
                setOnClickPendingIntent(R.id.widget_container, pendingIntent)

                // Actions using MediaButtonReceiver
                setOnClickPendingIntent(R.id.widget_prev, getMediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                
                // Toggle Play/Pause based on current state or just send generic PLAY_PAUSE?
                // Sending specific PLAY or PAUSE is safer if we know the state, but PLAY_PAUSE is standard toggle.
                // Since we update the ICON based on state, let's try sending the specific key code relative to what the user wants to do.
                // If isPlaying is true, button shows Pause icon, so user wants PAUSE.
                val isPlaying = widgetData.getBoolean("isPlaying", false)
                if (isPlaying) {
                    setOnClickPendingIntent(R.id.widget_play, getMediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_PAUSE))
                } else {
                    setOnClickPendingIntent(R.id.widget_play, getMediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_PLAY))
                }

                setOnClickPendingIntent(R.id.widget_next, getMediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_NEXT))

                // Restore state
                val title = widgetData.getString("title", "Forawn Music")
                val artist = widgetData.getString("artist", "Tap to play")
                val artworkPath = widgetData.getString("artwork_path", null)
                val dominantColor = widgetData.getLong("dominantColor", 0xFF212121L).toInt()

                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_artist, artist)
                
                // Update Background Color
                // setInt(viewId, "methodName", value) can be used for setBackgroundColor
                setInt(R.id.widget_container, "setBackgroundColor", dominantColor)

                // Update Artwork
                if (artworkPath != null) {
                     val imageFile = java.io.File(artworkPath)
                     if (imageFile.exists()) {
                         val myBitmap = android.graphics.BitmapFactory.decodeFile(imageFile.absolutePath)
                         setImageViewBitmap(R.id.widget_artwork, myBitmap)
                     } else {
                         setImageViewResource(R.id.widget_artwork, R.mipmap.ic_launcher)
                     }
                } else {
                    setImageViewResource(R.id.widget_artwork, R.mipmap.ic_launcher)
                }
                
                // Update Play/Pause icon
                if (isPlaying) {
                    setImageViewResource(R.id.widget_play, R.drawable.ic_pause)
                } else {
                    setImageViewResource(R.id.widget_play, R.drawable.ic_play_arrow)
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun getMediaButtonIntent(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
        intent.component = ComponentName(context, com.ryanheise.audioservice.MediaButtonReceiver::class.java)
        intent.putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        return PendingIntent.getBroadcast(context, keyCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
