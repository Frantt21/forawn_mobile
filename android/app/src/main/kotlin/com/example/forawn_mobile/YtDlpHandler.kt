package com.example.forawn_mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Wraps youtubedl-android (com.yausername.youtubedl_android) to run yt-dlp
 * on Android. Handles init, download, cancel and version check.
 * Portado de Scrup (YtDlpHandler.kt). También emite progreso en tiempo real
 * por el canal "forawn/ytdlp/progress" (EventChannel).
 */
class YtDlpHandler(private val context: Context) : EventChannel.StreamHandler {
    companion object {
        private const val TAG = "YtDlpHandler"
        private const val YTDLP_LATEST_URL =
            "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
        private const val PROGRESS_CHANNEL = "forawn/ytdlp/progress"
    }

    private var initialized = false
    private var currentProcessId: String? = null
    private var progressSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
        Log.i(TAG, "progress listener conectado")
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
        Log.i(TAG, "progress listener desconectado")
    }

    fun init() {
        if (initialized) return
        try {
            YoutubeDL.getInstance().init(context)
            // FFmpeg requiere SU PROPIO init (igual que el README de
            // youtubedl-android). Sin esto, yt-dlp no encuentra ffmpeg y el
            // post-proceso (--extract-audio/--embed-thumbnail) falla con
            // "'NoneType' object has no attribute 'lower'".
            FFmpeg.getInstance().init(context)
            initialized = true
            Log.i(TAG, "youtubedl-android initialized OK (python + ffmpeg)")
        } catch (e: Exception) {
            Log.e(TAG, "Init failed: ${e.message}", e)
        }
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ytdlpInit" -> {
                init()
                result.success(initialized)
            }
            "ytdlpRun" -> {
                val args = call.argument<List<String>>("args") ?: emptyList()
                executeYtDlp(args, result)
            }
            "ytdlpCancel" -> {
                try {
                    val pid = currentProcessId
                    if (pid != null) {
                        YoutubeDL.getInstance().destroyProcessById(pid)
                        currentProcessId = null
                    }
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "Cancel failed: $e")
                    result.success(false)
                }
            }
            "ytdlpVersion" -> {
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val request = YoutubeDLRequest(listOf("--version"))
                        val response = YoutubeDL.getInstance().execute(request)
                        val version = response.out.trim()
                        withContext(Dispatchers.Main) {
                            result.success(version.ifEmpty { "unknown" })
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Version check failed", e)
                        withContext(Dispatchers.Main) {
                            result.error("version", e.toString(), null)
                        }
                    }
                }
            }
            "ytdlpUpdate" -> updateYtDlp(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Actualiza yt-dlp embebido a la última versión ESTABLE desde GitHub
     * (mismo enfoque que Forawn desktop: usar siempre el yt-dlp más reciente).
     * YouTube rompe constantemente los clientes antiguos (HTTP 403), así que
     * esto reemplaza el binario envuelto en el APK sin recompilar.
     *
     * El update de la librería (UpdateChannel.STABLE) a veces falla en el
     * dispositivo (api.github.com bloqueada, timeouts cortos de la librería,
     * etc.). Fallback: descarga directa desde el release latest de GitHub al
     * MISMO path que lee la librería (<noBackupFilesDir>/youtubedl-android/)
     * y reapunta con init_ytdlp para que el próximo execute() use el binario
     * actualizado.
     *
     * Best-effort: nunca lanza error al canal, devuelve un status string.
     */
    private fun updateYtDlp(result: MethodChannel.Result) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (!initialized) init()
                var status: String
                try {
                    val st =
                        YoutubeDL.getInstance().updateYoutubeDL(
                            context,
                            YoutubeDL.UpdateChannel.STABLE,
                        )
                    status = st?.name?.takeIf { it.isNotBlank() } ?: "UPDATED"
                    Log.i(TAG, "yt-dlp update (librería) status=$status")
                } catch (e: Exception) {
                    Log.w(TAG, "yt-dlp update (librería) falló: ${e.message}")
                    // Fallback: descarga manual del zipapp latest.
                    if (manualUpdateYtDlp()) {
                        status = "UPDATED_DIRECT"
                        Log.i(TAG, "yt-dlp actualizado por descarga directa")
                    } else {
                        status = "FAILED: ${e.message}"
                    }
                }
                withContext(Dispatchers.Main) { result.success(status) }
            } catch (e: Exception) {
                Log.w(TAG, "yt-dlp update failed: ${e.message}")
                withContext(Dispatchers.Main) { result.success("FAILED") }
            }
        }
    }

    /**
     * Descarga el zipapp `yt-dlp` del release latest de yt-dlp (GitHub) y lo
     * coloca donde la librería lo lee. Validación mínima del binario (hex de
     * arranque de Python zipapp) para descartar páginas de error/HTML.
     */
    private fun manualUpdateYtDlp(): Boolean {
        var tmp: File? = null
        return try {
            val dir = File(context.noBackupFilesDir, "youtubedl-android")
            dir.mkdirs()
            tmp = File.createTempFile("ytdlp", ".zipapp", context.cacheDir)
            val conn = URL(YTDLP_LATEST_URL).openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.instanceFollowRedirects = true
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            val code = conn.responseCode
            if (code !in 200..299) {
                Log.w(TAG, "manualUpdateYtDlp: HTTP $code")
                return false
            }
            conn.inputStream.use { input ->
                tmp.outputStream().use { out -> input.copyTo(out) }
            }
            // yt-dlp zipapp empieza con shebang python (#!/usr/bin/env python3);
            // una página de error/HTML de GitHub no lo tiene.
            val bytes = tmp.inputStream().use { it.readNBytes(16) }
            val head = String(bytes, Charsets.ISO_8859_1)
            if (!head.startsWith("#!")) {
                Log.w(TAG, "manualUpdateYtDlp: binario descargado no válido")
                return false
            }
            val target = File(dir, "yt-dlp")
            if (target.exists()) target.delete()
            tmp.copyTo(target, overwrite = true)
            target.setExecutable(true, false)
            // Re-apunta la librería al binario nuevo (si no existe lo copia
            // del raw; aquí ya existe así que no toca nada).
            YoutubeDL.getInstance().init_ytdlp(context, dir)
            Log.i(TAG, "manualUpdateYtDlp OK: ${target.length()} bytes -> ${target.path}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "manualUpdateYtDlp falló: ${e.message}")
            false
        } finally {
            tmp?.delete()
        }
    }

    /**
     * Execute yt-dlp with the given args. Dart builds the full argument list
     * (URLs, flags and values). Returns a map with exitCode/output/error.
     */
    private fun executeYtDlp(args: List<String>, result: MethodChannel.Result) {
        if (!initialized) {
            result.error("notInitialized", "youtubedl-android not initialized", null)
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                Log.i(TAG, "Executing: ${args.joinToString(" ")}")

                val request = YoutubeDLRequest(emptyList())
                request.addCommands(args)

                val processId = "forawn_${System.currentTimeMillis()}"
                currentProcessId = processId

                val response = YoutubeDL.getInstance().execute(request, processId) { progress, _, _ ->
                    // yt-dlp reporta 0..100; normalizar a 0..1. -1.0 = descarga
                    // de algo extra (EVA/thumbnail); ignorar en esos casos.
                    if (progress != null && progress >= 0f) {
                        val pct = (progress / 100f).coerceIn(0f, 1f)
                        val mainHandler = Handler(Looper.getMainLooper())
                        mainHandler.post {
                            progressSink?.success(hashMapOf("progress" to pct))
                        }
                    }
                }
                currentProcessId = null

                Log.i(TAG, "yt-dlp exit=${response.exitCode} out=${response.out.take(200)}")

                withContext(Dispatchers.Main) {
                    val resultMap = hashMapOf<String, Any?>(
                        "exitCode" to response.exitCode,
                        "output" to response.out,
                        "error" to response.err
                    )
                    result.success(resultMap)
                }
            } catch (e: com.yausername.youtubedl_android.YoutubeDLException) {
                // Non-zero exit: library throws instead of returning the exit
                // code. Return it as a result map so Dart can parse it.
                currentProcessId = null
                val errMsg = e.message ?: "yt-dlp error"
                Log.e(TAG, "yt-dlp error: $errMsg")
                withContext(Dispatchers.Main) {
                    val resultMap = hashMapOf<String, Any?>(
                        "exitCode" to 1,
                        "output" to errMsg,
                        "error" to errMsg
                    )
                    result.success(resultMap)
                }
            } catch (e: Exception) {
                currentProcessId = null
                Log.e(TAG, "Execution failed: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    result.error("execution", e.message ?: "Unknown error", e.stackTraceToString())
                }
            }
        }
    }
}
