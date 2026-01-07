package com.example.forawn_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import androidx.annotation.NonNull
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity


class MainActivity : AudioServiceActivity() {
  private val CHANNEL = "forawn/saf"
  private val PICK_DIR_REQUEST = 1001
  private var pendingResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

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
          try {
            val list = listFilesFromTree(Uri.parse(treeUri))
            result.success(list)
          } catch (e: Exception) {
            result.error("LIST_ERROR", e.message, null)
          }
        }

        "saveFileFromPath" -> {
          val treeUri = call.argument<String>("treeUri")
          val tempPath = call.argument<String>("tempPath")
          val fileName = call.argument<String>("fileName")
          if (treeUri == null || tempPath == null || fileName == null) {
            result.error("INVALID_ARGS", "missing args", null)
            return@setMethodCallHandler
          }
          try {
            val savedUri = saveFileToTree(Uri.parse(treeUri), tempPath, fileName)
            result.success(savedUri?.toString())
          } catch (e: Exception) {
            result.error("SAVE_ERROR", e.message, null)
          }
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
          try {
            val ok = deleteSafFile(Uri.parse(uriStr))
            result.success(ok)
          } catch (e: Exception) {
            result.error("DELETE_ERROR", e.message, null)
          }
        }

        "readBytesFromUri" -> {
          val uriString = call.argument<String>("uri")
          val maxBytes = call.argument<Int>("maxBytes") ?: (512 * 1024)
          if (uriString == null) {
            result.error("INVALID_ARGUMENT", "URI is null", null)
            return@setMethodCallHandler
          }
          try {
            val bytes = readBytesFromUri(Uri.parse(uriString), maxBytes)
            result.success(bytes)
          } catch (e: Exception) {
            result.error("READ_ERROR", e.message, null)
          }
        }

        "getFreeSpace" -> {
          try {
            val freeSpace = getFreeSpace()
            result.success(freeSpace)
          } catch (e: Exception) {
            result.error("FREE_SPACE_ERROR", e.message, null)
          }
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
          try {
            val metadata = getMetadataFromUri(Uri.parse(uriStr))
            result.success(metadata)
          } catch (e: Exception) {
            result.error("METADATA_ERROR", e.message, null)
          }
        }

        "overwriteFileFromPath" -> {
          val uriStr = call.argument<String>("uri")
          val tempPath = call.argument<String>("tempPath")
          if (uriStr == null || tempPath == null) {
            result.error("INVALID_ARGS", "missing args", null)
            return@setMethodCallHandler
          }
          try {
            val ok = overwriteFileFromPath(Uri.parse(uriStr), tempPath)
            result.success(ok)
          } catch (e: Exception) {
            result.error("WRITE_ERROR", e.message, null)
          }
        }

        "copyUriToFile" -> {
          val uriStr = call.argument<String>("uri")
          val destPath = call.argument<String>("destPath")
          if (uriStr == null || destPath == null) {
              result.error("INVALID_ARGS", "missing args", null)
              return@setMethodCallHandler
          }
          try {
              val ok = copyUriToFile(Uri.parse(uriStr), destPath)
              result.success(ok)
          } catch(e: Exception) {
              result.error("COPY_ERROR", e.message, null)
          }
        }

  // Nuevo: Obtener metadatos desde MediaStore (más rápido y robusto para artworks)
  "getMetadataFromMediaStore" -> {
    val filePath = call.argument<String>("filePath")
    if (filePath == null) {
      result.error("INVALID_ARGS", "filePath is null", null)
      return@setMethodCallHandler
    }
    try {
      val metadata = getMetadataFromMediaStore(filePath)
      result.success(metadata)
    } catch (e: Exception) {
      result.error("MEDIASTORE_ERROR", e.message, null)
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
      val newFile = dir.createFile("audio/mpeg", fileName) ?: return null
      
      try {
          val inputStream = FileInputStream(File(tempFilePath))
          val outputStream = contentResolver.openOutputStream(newFile.uri)
          if (outputStream != null) {
              inputStream.use { input ->
                  outputStream.use { output ->
                      input.copyTo(output)
                  }
              }
              return newFile.uri
          }
      } catch (e: Exception) {
          e.printStackTrace()
          newFile.delete()
          throw e
      }
      return null
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
          val outputStream = File(destPath).outputStream()
          if (inputStream != null) {
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
}
