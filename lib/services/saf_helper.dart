// lib/services/saf_helper.dart
import 'dart:async';
import 'package:flutter/services.dart';

class SafHelper {
  static const MethodChannel _channel = MethodChannel('forawn/saf');

  static Future<String?> pickDirectory() async {
    try {
      final String? uri = await _channel.invokeMethod<String>('pickDirectory');
      return uri;
    } catch (e) {
      print('pickDirectory error: $e');
      return null;
    }
  }

  static Future<String?> saveFileFromPath({
    required String treeUri,
    required String tempPath,
    required String fileName,
  }) async {
    try {
      final String? savedUri = await _channel.invokeMethod<String>(
        'saveFileFromPath',
        {'treeUri': treeUri, 'tempPath': tempPath, 'fileName': fileName},
      );
      return savedUri;
    } catch (e) {
      print('saveFileFromPath error: $e');
      return null;
    }
  }

  static Future<List<Map<String, String>>?> listFilesFromTree(
    String treeUri,
  ) async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod<List<dynamic>>(
        'listFilesFromTree',
        {'treeUri': treeUri},
      );
      if (result == null) return null;
      final List<Map<String, String>> out = [];
      for (final item in result) {
        if (item is Map) {
          final name = item['name']?.toString() ?? '';
          final uri = item['uri']?.toString() ?? '';
          out.add({'name': name, 'uri': uri});
        }
      }
      return out;
    } catch (e) {
      print('listFilesFromTree error: $e');
      return null;
    }
  }

  // Nuevo: abrir un archivo SAF (lanza intent VIEW)
  static Future<bool> openFileFromUri(String uri) async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('openSafFile', {
        'uri': uri,
      });
      return res ?? false;
    } catch (e) {
      print('openFileFromUri error: $e');
      return false;
    }
  }

  // Nuevo: eliminar archivo SAF
  static Future<bool> deleteFileFromUri(String uri) async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('deleteSafFile', {
        'uri': uri,
      });
      return res ?? false;
    } catch (e) {
      print('deleteFileFromUri error: $e');
      return false;
    }
  }

  // Nuevo: compartir archivo SAF (lanza intent SEND)
  static Future<bool> shareFileFromUri(
    String uri,
    String mimeType,
    String? subject,
  ) async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('shareSafFile', {
        'uri': uri,
        'mimeType': mimeType,
        'subject': subject ?? '',
      });
      return res ?? false;
    } catch (e) {
      print('shareFileFromUri error: $e');
      return false;
    }
  }

  // Nuevo: leer bytes de un archivo SAF para mostrar vista previa
  static Future<Uint8List?> readBytesFromUri(
    String uri, {
    int maxBytes = 512 * 1024,
  }) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
        'readBytesFromUri',
        {'uri': uri, 'maxBytes': maxBytes},
      );
      return bytes;
    } catch (e) {
      print('readBytesFromUri error: $e');
      return null;
    }
  }

  // Nuevo: Obtener metadatos desde URI (Saf)
  static Future<Map<String, dynamic>?> getMetadataFromUri(String uri) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getMetadataFromUri',
        {'uri': uri},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      print('getMetadataFromUri error: $e');
      return null;
    }
  }
}
