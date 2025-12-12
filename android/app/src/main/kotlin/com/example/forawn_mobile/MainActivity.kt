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
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import androidx.core.content.FileProvider

class MainActivity : FlutterActivity() {
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

        else -> {
          result.notImplemented()
        }
      }
    }
  }

  // --- SAF and helper implementations ---

  private fun openDirectoryPicker() {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    startActivityForResult(intent, PICK_DIR_REQUEST)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == PICK_DIR_REQUEST) {
      if (resultCode == Activity.RESULT_OK && data != null) {
        val treeUri = data.data
        if (treeUri != null) {
          contentResolver.takePersistableUriPermission(
            treeUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
          )
          pendingResult?.success(treeUri.toString())
        } else {
          pendingResult?.success(null)
        }
      } else {
        pendingResult?.success(null)
      }
      pendingResult = null
    }
  }

  private fun listFilesFromTree(treeUri: Uri): List<Map<String, String>> {
    val doc = DocumentFile.fromTreeUri(this, treeUri) ?: throw Exception("Invalid treeUri")
    val children = doc.listFiles()
    val out = ArrayList<Map<String, String>>()
    for (child in children) {
      val name = child.name ?: continue
      val uri = child.uri.toString()
      out.add(mapOf("name" to name, "uri" to uri))
    }
    return out
  }

  private fun saveFileToTree(treeUri: Uri, tempPath: String, fileName: String): Uri? {
    val treeDoc = DocumentFile.fromTreeUri(this, treeUri) ?: throw Exception("Invalid treeUri")
    treeDoc.findFile(fileName)?.delete()
    val newFile = treeDoc.createFile("application/octet-stream", fileName) ?: throw Exception("Cannot create file")
    val outUri = newFile.uri
    val input = FileInputStream(File(tempPath))
    val output: OutputStream? = contentResolver.openOutputStream(outUri)
    output?.use { outStream ->
      val buffer = ByteArray(8192)
      var read: Int
      while (input.read(buffer).also { read = it } != -1) {
        outStream.write(buffer, 0, read)
      }
      outStream.flush()
    }
    input.close()
    return outUri
  }

  private fun openSafFile(uri: Uri): Boolean {
    return try {
      val intent = Intent(Intent.ACTION_VIEW)
      intent.setDataAndType(uri, contentResolver.getType(uri))
      intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      startActivity(intent)
      true
    } catch (e: ActivityNotFoundException) {
      false
    }
  }

  private fun deleteSafFile(uri: Uri): Boolean {
    return try {
      DocumentFile.fromSingleUri(this, uri)?.delete() ?: false
    } catch (e: Exception) {
      false
    }
  }

  private fun readBytesFromUri(uri: Uri, maxBytes: Int): ByteArray? {
    return try {
      contentResolver.openInputStream(uri)?.use { inputStream ->
        val buffer = ByteArray(maxBytes)
        val bytesRead = inputStream.read(buffer)
        if (bytesRead == -1) {
          null
        } else {
          buffer.copyOf(bytesRead)
        }
      }
    } catch (e: Exception) {
      e.printStackTrace()
      null
    }
  }

  private fun getFreeSpace(): Long {
    val path = Environment.getDataDirectory()
    val stat = StatFs(path.path)
    val blockSize = stat.blockSizeLong
    val availableBlocks = stat.availableBlocksLong
    return availableBlocks * blockSize
  }

  private fun shareSafFile(uri: Uri, mimeType: String, subject: String): Boolean {
    return try {
      val shareIntent = Intent(Intent.ACTION_SEND)
      shareIntent.type = mimeType
      shareIntent.putExtra(Intent.EXTRA_STREAM, uri)
      if (subject.isNotEmpty()) shareIntent.putExtra(Intent.EXTRA_SUBJECT, subject)
      shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      val chooser = Intent.createChooser(shareIntent, null)
      startActivity(chooser)
      true
    } catch (e: Exception) {
      false
    }
  }
}
