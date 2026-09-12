package com.example.forawn_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import androidx.annotation.NonNull
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity


class MainActivity : AudioServiceActivity() {
  private val CHANNEL = "forawn/saf"
  private val YTDLP_CHANNEL = "forawn/ytdlp"
  private val YTDLP_PROGRESS_CHANNEL = "forawn/ytdlp/progress"
  private val PICK_DIR_REQUEST = 1001
  private var pendingResult: MethodChannel.Result? = null
  private var ytDlpHandler: YtDlpHandler? = null

  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    // Canal de yt-dlp (youtubedl-android): init/run/cancel/version.
    ytDlpHandler = YtDlpHandler(this)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YTDLP_CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "ytdlpInit", "ytdlpRun", "ytdlpCancel", "ytdlpVersion", "ytdlpUpdate" -> {
          ytDlpHandler!!.handleMethodCall(call, result)
        }
        else -> result.notImplemented()
      }
    }
    // Progreso en tiempo real de yt-dlp (0..1).
    EventChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      YTDLP_PROGRESS_CHANNEL,
    ).setStreamHandler(ytDlpHandler)
    // Inicializar youtubedl-android en background (extrae Python/yt-dlp/FFmpeg).
    Thread {
      try {
        ytDlpHandler?.init()
      } catch (e: Exception) {
        android.util.Log.e("forawn", "Failed to init youtubedl-android", e)
      }
    }.start()

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "pickDirectory" -> {
          pendingResult = result
          openDirectoryPicker()
        }

        "listFilesFromTree" -> {
          val treeUri = call.argument<String>("treeUri")
          if (treeUri == null) {
            result.error("INVALID_ARGS", "treeUri is null", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val list = listFilesFromTree(Uri.parse(treeUri))
              runOnUiThread { result.success(list) }
            } catch (e: Exception) {
              runOnUiThread { result.error("LIST_ERROR", e.message, null) }
            }
          }.start()
        }

        "saveFileFromPath" -> {
          val treeUri = call.argument<String>("treeUri")
          val tempPath = call.argument<String>("tempPath")
          val fileName = call.argument<String>("fileName")
          if (treeUri == null || tempPath == null || fileName == null) {
            result.error("INVALID_ARGS", "missing args", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val savedUri = saveFileToTree(Uri.parse(treeUri), tempPath, fileName)
              runOnUiThread { result.success(savedUri?.toString()) }
            } catch (e: Exception) {
              runOnUiThread { result.error("SAVE_ERROR", e.message, null) }
            }
          }.start()
        }

        "openSafFile" -> {
          val uriStr = call.argument<String>("uri")
          if (uriStr == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return@setMethodCallHandler
          }
          try {
            val ok = openSafFile(Uri.parse(uriStr))
            result.success(ok)
          } catch (e: Exception) {
            result.error("OPEN_ERROR", e.message, null)
          }
        }

        "deleteSafFile" -> {
          val uriStr = call.argument<String>("uri")
          if (uriStr == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val ok = deleteSafFile(Uri.parse(uriStr))
              runOnUiThread { result.success(ok) }
            } catch (e: Exception) {
              runOnUiThread { result.error("DELETE_ERROR", e.message, null) }
            }
          }.start()
        }

        "deleteFile" -> {
          val uriStr = call.argument<String>("uri")
          if (uriStr == null) {
             result.error("INVALID_ARGS", "uri is null", null)
             return@setMethodCallHandler
          }
          Thread {
            try {
               // Try deleting as regular file first if not content://
               val file = File(uriStr)
               if (file.exists()) {
                   val deleted = file.delete()
                   runOnUiThread { result.success(deleted) }
                   return@Thread
               }
               // If not regular file or not exists, try SAF
               val ok = deleteSafFile(Uri.parse(uriStr))
               runOnUiThread { result.success(ok) }
            } catch(e: Exception) {
               runOnUiThread { result.error("DELETE_ERROR", e.message, null) }
            }
          }.start()
        }

        "readBytesFromUri" -> {
          val uriString = call.argument<String>("uri")
          val maxBytes = call.argument<Int>("maxBytes") ?: (512 * 1024)
          if (uriString == null) {
            result.error("INVALID_ARGUMENT", "URI is null", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val bytes = readBytesFromUri(Uri.parse(uriString), maxBytes)
              runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
              runOnUiThread { result.error("READ_ERROR", e.message, null) }
            }
          }.start()
        }

        "getFreeSpace" -> {
          Thread {
            try {
              val freeSpace = getFreeSpace()
              runOnUiThread { result.success(freeSpace) }
            } catch (e: Exception) {
              runOnUiThread { result.error("FREE_SPACE_ERROR", e.message, null) }
            }
          }.start()
        }

        "shareSafFile" -> {
          val uriStr = call.argument<String>("uri")
          val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
          val subject = call.argument<String>("subject") ?: ""
          if (uriStr == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return@setMethodCallHandler
          }
          try {
            val ok = shareSafFile(Uri.parse(uriStr), mimeType, subject)
            result.success(ok)
          } catch (e: Exception) {
            result.error("SHARE_ERROR", e.message, null)
          }
        }

        "getMetadataFromUri" -> {
          val uriStr = call.argument<String>("uri")
          if (uriStr == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val metadata = getMetadataFromUri(Uri.parse(uriStr))
              runOnUiThread { result.success(metadata) }
            } catch (e: Exception) {
              runOnUiThread { result.error("METADATA_ERROR", e.message, null) }
            }
          }.start()
        }

        "overwriteFileFromPath" -> {
          val uriStr = call.argument<String>("uri")
          val tempPath = call.argument<String>("tempPath")
          if (uriStr == null || tempPath == null) {
            result.error("INVALID_ARGS", "missing args", null)
            return@setMethodCallHandler
          }
          Thread {
            try {
              val ok = overwriteFileFromPath(Uri.parse(uriStr), tempPath)
              runOnUiThread { result.success(ok) }
            } catch (e: Exception) {
              runOnUiThread { result.error("WRITE_ERROR", e.message, null) }
            }
          }.start()
        }

        "copyUriToFile" -> {
          val uriStr = call.argument<String>("uri")
          val destPath = call.argument<String>("destPath")
          if (uriStr == null || destPath == null) {
              result.error("INVALID_ARGS", "missing args", null)
              return@setMethodCallHandler
          }
          Thread {
              try {
                  val ok = copyUriToFile(Uri.parse(uriStr), destPath)
                  runOnUiThread { result.success(ok) }
              } catch(e: Exception) {
                  runOnUiThread { result.error("COPY_ERROR", e.message, null) }
              }
          }.start()
        }

  // Nuevo: Obtener metadatos desde MediaStore (más rápido y robusto para artworks)
  "getMetadataFromMediaStore" -> {
    val filePath = call.argument<String>("filePath")
    if (filePath == null) {
      result.error("INVALID_ARGS", "filePath is null", null)
      return@setMethodCallHandler
    }
    Thread {
      try {
        val metadata = getMetadataFromMediaStore(filePath)
        runOnUiThread { result.success(metadata) }
      } catch (e: Exception) {
        runOnUiThread { result.error("MEDIASTORE_ERROR", e.message, null) }
      }
    }.start()
  }

  "openAccessibilitySettings" -> {
    try {
      val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
      startActivity(intent)
      result.success(true)
    } catch (e: Exception) {
      result.error("OPEN_ACCESSIBILITY_ERROR", e.message, null)
    }
  }

        else -> {
          result.notImplemented()
        }
      }
    }
  }

  private fun openDirectoryPicker() {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
    intent.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    startActivityForResult(intent, PICK_DIR_REQUEST)
  }

  override fun onResume() {
    super.onResume()
    // Android 13+ (API 33): POST_NOTIFICATIONS es un permiso en runtime.
    // Sin él la notificación multimedia no aparece (Scrup lo pide igual).
    requestNotificationPermission()
  }

  private fun requestNotificationPermission() {
    if (Build.VERSION.SDK_INT < 33) return
    if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
      PackageManager.PERMISSION_GRANTED
    ) return
    requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == PICK_DIR_REQUEST) {
      if (resultCode == Activity.RESULT_OK && data != null) {
        val uri = data.data
        if (uri != null) {
          contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
          )
          pendingResult?.success(uri.toString())
        } else {
          pendingResult?.error("URI_NULL", "Uri is null", null)
        }
      } else {
        pendingResult?.error("CANCELED", "User canceled", null)
      }
      pendingResult = null
    }
  }

  private fun listFilesFromTree(treeUri: Uri): List<Map<String, Any>> {
    val resultList = mutableListOf<Map<String, Any>>()
    val dir = DocumentFile.fromTreeUri(this, treeUri)
    if (dir != null && dir.canRead()) {
      val files = dir.listFiles()
      for (file in files) {
        if (!file.isDirectory && file.name?.endsWith(".mp3", ignoreCase = true) == true) {
            val fileMap = mapOf(
                "uri" to file.uri.toString(),
                "name" to (file.name ?: "unknown"),
                "size" to file.length()
            )
            resultList.add(fileMap)
        }
      }
    }
    return resultList
  }

  private fun saveFileToTree(treeUri: Uri, tempFilePath: String, fileName: String): Uri? {
      val dir = DocumentFile.fromTreeUri(this, treeUri) ?: return null
      // MIME derivado de la extensión real del archivo. Antes se forzaba
      // "audio/mpeg" y SAF le AÑADÍA ".mp3" a cualquier nombre que no
      // coincidiera (ej. "Video.mp4" -> "Video.mp4.mp3").
      val newFile = dir.createFile(mimeForFileName(fileName), fileName) ?: return null
      
      try {
          val sourceFile = File(tempFilePath)
          val sourceSize = sourceFile.length()
          android.util.Log.d("MainActivity", "Saving file: $fileName, source size: $sourceSize bytes")
          
          val inputStream = FileInputStream(sourceFile)
          val outputStream = contentResolver.openOutputStream(newFile.uri)
          if (outputStream != null) {
              var bytesCopied = 0L
              inputStream.use { input ->
                  outputStream.use { output ->
                      bytesCopied = input.copyTo(output)
                  }
              }
              
              // Validar que se copiaron todos los bytes
              if (bytesCopied != sourceSize) {
                  android.util.Log.e("MainActivity", "File copy incomplete! Expected: $sourceSize, Copied: $bytesCopied")
                  newFile.delete()
                  throw Exception("File copy incomplete: expected $sourceSize bytes, copied $bytesCopied bytes")
              }
              
              android.util.Log.d("MainActivity", "File saved successfully: $bytesCopied bytes")
              return newFile.uri
          }
      } catch (e: Exception) {
          e.printStackTrace()
          android.util.Log.e("MainActivity", "Error saving file", e)
          newFile.delete()
          throw e
      }
      return null
  }

  /** MIME type según la extensión del nombre de archivo destino. */
  private fun mimeForFileName(name: String): String {
      val ext = name.substringAfterLast('.', "").lowercase()
      return when (ext) {
          "mp3" -> "audio/mpeg"
          "m4a" -> "audio/mp4"
          "opus", "ogg" -> "audio/ogg"
          "wav" -> "audio/wav"
          "flac" -> "audio/flac"
          "mp4" -> "video/mp4"
          "webm" -> "video/webm"
          "mkv" -> "video/x-matroska"
          "mov" -> "video/quicktime"
          "jpg", "jpeg" -> "image/jpeg"
          "png" -> "image/png"
          else -> "application/octet-stream"
      }
  }

  private fun openSafFile(uri: Uri): Boolean {
      return try {
          val intent = Intent(Intent.ACTION_VIEW)
          intent.setDataAndType(uri, "audio/*")
          intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
          startActivity(intent)
          true
      } catch (e: Exception) {
          false
      }
  }

  private fun deleteSafFile(uri: Uri): Boolean {
      return try {
          val file = DocumentFile.fromSingleUri(this, uri)
          file?.delete() ?: false
      } catch (e: Exception) {
          false
      }
  }

  private fun readBytesFromUri(uri: Uri, maxBytes: Int): ByteArray? {
      return try {
          contentResolver.openInputStream(uri)?.use { inputStream ->
              val buffer = ByteArray(maxBytes)
              val bytesRead = inputStream.read(buffer)
              if (bytesRead > 0) {
                  buffer.copyOf(bytesRead)
              } else {
                  null
              }
          }
      } catch (e: Exception) {
          e.printStackTrace()
          null
      }
  }

  private fun getFreeSpace(): Long {
      val stat = StatFs(Environment.getDataDirectory().path)
      return stat.availableBlocksLong * stat.blockSizeLong
  }

  private fun shareSafFile(uri: Uri, mimeType: String, subject: String): Boolean {
      return try {
          val shareIntent = Intent(Intent.ACTION_SEND)
          shareIntent.type = mimeType
          shareIntent.putExtra(Intent.EXTRA_STREAM, uri)
          shareIntent.putExtra(Intent.EXTRA_SUBJECT, subject)
          shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
          startActivity(Intent.createChooser(shareIntent, "Share Song"))
          true
      } catch (e: Exception) {
          false
      }
  }
  
  private fun getMetadataFromMediaStore(filePath: String): Map<String, Any?>? {
      val projection = arrayOf(
          android.provider.MediaStore.Audio.Media._ID,
          android.provider.MediaStore.Audio.Media.TITLE,
          android.provider.MediaStore.Audio.Media.ARTIST,
          android.provider.MediaStore.Audio.Media.ALBUM,
          android.provider.MediaStore.Audio.Media.DURATION,
          android.provider.MediaStore.Audio.Media.ALBUM_ID
      )
      val selection = "${android.provider.MediaStore.Audio.Media.DATA} = ?"
      val selectionArgs = arrayOf(filePath)

      contentResolver.query(
          android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
          projection,
          selection,
          selectionArgs,
          null
      )?.use { cursor ->
          if (cursor.moveToFirst()) {
              val title = cursor.getString(cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.TITLE))
              val artist = cursor.getString(cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ARTIST))
              val album = cursor.getString(cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ALBUM))
              val duration = cursor.getLong(cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DURATION))
              val albumId = cursor.getLong(cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ALBUM_ID))

              val artworkUri = "content://media/external/audio/albumart/$albumId"

              return mapOf(
                  "title" to title,
                  "artist" to artist,
                  "album" to album,
                  "duration" to duration,
                  "artworkUri" to artworkUri
              )
          }
      }
      return null
  }

  private fun getMetadataFromUri(uri: Uri): Map<String, Any?> {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(this, uri)
      val title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
      val artist = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
      val album = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
      val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
      val picture = retriever.embeddedPicture

      mapOf(
        "title" to title,
        "artist" to artist,
        "album" to album,
        "duration" to durationStr?.toLongOrNull(),
        "artworkData" to picture
      )
    } catch (e: Exception) {
      e.printStackTrace()
      mapOf()
    } finally {
      retriever.release()
    }
  }

  private fun overwriteFileFromPath(uri: Uri, tempPath: String): Boolean {
      try {
          val inputStream = FileInputStream(File(tempPath))
          // "wt" mode truncates the file content before writing
          val outputStream = contentResolver.openOutputStream(uri, "wt") 
          if (outputStream != null) {
              inputStream.use { input ->
                  outputStream.use { output ->
                      input.copyTo(output)
                  }
              }
              return true
          }
      } catch (e: Exception) {
          e.printStackTrace()
          throw e
      }
      return false
  }

  private fun copyUriToFile(uri: Uri, destPath: String): Boolean {
      try {
          val inputStream = contentResolver.openInputStream(uri)
          if (inputStream != null) {
              inputStream.use { input ->
                  // Skip ID3v2 tags if present to create a cleaner MP3 file
                  val buffer = ByteArray(10)
                  var bytesRead = input.read(buffer)
                  
                  var skipBytes = 0L
                  // Check for ID3v2 header: "ID3"
                  if (bytesRead >= 10 && 
                      buffer[0] == 'I'.code.toByte() && 
                      buffer[1] == 'D'.code.toByte() && 
                      buffer[2] == '3'.code.toByte()) {
                      
                      // ID3v2 size is stored in bytes 6-9 as synchsafe integer
                      val size = ((buffer[6].toInt() and 0x7F) shl 21) or
                                 ((buffer[7].toInt() and 0x7F) shl 14) or
                                 ((buffer[8].toInt() and 0x7F) shl 7) or
                                 (buffer[9].toInt() and 0x7F)
                      
                      skipBytes = size + 10L // +10 for header itself
                      android.util.Log.d("MainActivity", "Skipping ID3v2 tag: $skipBytes bytes")
                      
                      // Skip the tag
                      input.skip(skipBytes - 10) // -10 because we already read header
                  }
                  
                  // Now copy the actual MP3 data
                  File(destPath).outputStream().use { output ->
                      if (skipBytes == 0L) {
                          // No ID3 tag, write the header we read
                          output.write(buffer, 0, bytesRead)
                      }
                      // Copy the rest
                      input.copyTo(output)
                  }
              }
              return true
          } 
      } catch (e: Exception) {
          e.printStackTrace()
          android.util.Log.e("MainActivity", "Error copying URI to file", e)
          throw e
      }
      return false
  }
}
