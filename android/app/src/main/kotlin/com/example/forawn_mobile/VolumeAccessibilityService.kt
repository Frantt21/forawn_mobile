package com.example.forawn_mobile

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.util.Log

class VolumeAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var volumeUpRunnable: Runnable? = null
    private var volumeDownRunnable: Runnable? = null
    private val LONG_PRESS_TIMEOUT: Long = 500

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onKeyEvent(event: KeyEvent): Boolean {
        // Obtenemos PowerManager para verificar si la pantalla está encendida
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            // Si la pantalla está prendida, no hacemos nada extra, funciona normal
            return super.onKeyEvent(event)
        }

        val action = event.action
        val keyCode = event.keyCode

        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (action == KeyEvent.ACTION_DOWN) {
                if (event.repeatCount == 0) {
                    volumeUpRunnable = Runnable {
                        Log.d("VolumeAccessibility", "Volume UP long press -> NEXT")
                        simulateMediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
                        volumeUpRunnable = null
                    }
                    handler.postDelayed(volumeUpRunnable!!, LONG_PRESS_TIMEOUT)
                }
            } else if (action == KeyEvent.ACTION_UP) {
                volumeUpRunnable?.let {
                    // Si se soltó el botón antes del timeout, cancelamos el salto de canción
                    // IMPORTANTE: Dejamos que el sistema cambie el volumen si fue un toque corto
                    handler.removeCallbacks(it)
                    volumeUpRunnable = null
                }
            }
            // Retornamos sin interceptarlo para que el volumen base (si la config de android lo permite apagado) se cambie.
            return super.onKeyEvent(event)
        } else if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (action == KeyEvent.ACTION_DOWN) {
                if (event.repeatCount == 0) {
                    volumeDownRunnable = Runnable {
                        Log.d("VolumeAccessibility", "Volume DOWN long press -> PREVIOUS")
                        simulateMediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                        volumeDownRunnable = null
                    }
                    handler.postDelayed(volumeDownRunnable!!, LONG_PRESS_TIMEOUT)
                }
            } else if (action == KeyEvent.ACTION_UP) {
                volumeDownRunnable?.let {
                    handler.removeCallbacks(it)
                    volumeDownRunnable = null
                }
            }
            return super.onKeyEvent(event)
        }
        
        return super.onKeyEvent(event)
    }

    private fun simulateMediaKey(keyCode: Int) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val downEvent = KeyEvent(KeyEvent.ACTION_DOWN, keyCode)
        audioManager.dispatchMediaKeyEvent(downEvent)
        val upEvent = KeyEvent(KeyEvent.ACTION_UP, keyCode)
        audioManager.dispatchMediaKeyEvent(upEvent)
    }
}
