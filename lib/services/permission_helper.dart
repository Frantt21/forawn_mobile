// lib/services/permission_helper.dart
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

class PermissionHelper {
  /// Solicitar permisos de almacenamiento según la versión de Android
  /// Retorna true si se concedieron los permisos necesarios
  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      // Obtener información del SDK de Android
      final androidInfo = await _getAndroidVersion();

      // Android 13+ (API 33+): Usar permisos granulares
      if (androidInfo >= 33) {
        print(
          '[PermissionHelper] Android 13+ detectado, solicitando permisos granulares',
        );

        // Solicitar permisos de medios (audio es el más importante para esta app)
        final audioStatus = await Permission.audio.request();
        await Permission.photos.request();
        await Permission.videos.request();

        // Si al menos audio está concedido, consideramos suficiente
        if (audioStatus.isGranted) {
          print('[PermissionHelper] Permiso de audio concedido');
          return true;
        }

        // Si no, intentar MANAGE_EXTERNAL_STORAGE como último recurso
        print(
          '[PermissionHelper] Permisos granulares denegados, intentando MANAGE_EXTERNAL_STORAGE',
        );
        final manageStatus = await Permission.manageExternalStorage.request();

        if (manageStatus.isGranted) {
          print('[PermissionHelper] MANAGE_EXTERNAL_STORAGE concedido');
          return true;
        }

        // Si el usuario denegó permanentemente, mostrar configuración
        if (audioStatus.isPermanentlyDenied ||
            manageStatus.isPermanentlyDenied) {
          print('[PermissionHelper] Permisos denegados permanentemente');
          await openAppSettings();
          return false;
        }

        print('[PermissionHelper] Permisos denegados');
        return false;
      }
      // Android 11-12 (API 30-32): Intentar MANAGE_EXTERNAL_STORAGE primero
      else if (androidInfo >= 30) {
        print('[PermissionHelper] Android 11-12 detectado');

        // Verificar si ya tenemos MANAGE_EXTERNAL_STORAGE
        if (await Permission.manageExternalStorage.isGranted) {
          print('[PermissionHelper] MANAGE_EXTERNAL_STORAGE ya concedido');
          return true;
        }

        // Solicitar MANAGE_EXTERNAL_STORAGE
        final manageStatus = await Permission.manageExternalStorage.request();
        if (manageStatus.isGranted) {
          print('[PermissionHelper] MANAGE_EXTERNAL_STORAGE concedido');
          return true;
        }

        // Fallback a storage normal
        if (await Permission.storage.isGranted) {
          print('[PermissionHelper] Storage permission ya concedido');
          return true;
        }

        final storageStatus = await Permission.storage.request();
        if (storageStatus.isGranted) {
          print('[PermissionHelper] Storage permission concedido');
          return true;
        }

        // Si denegado permanentemente, abrir configuración
        if (manageStatus.isPermanentlyDenied ||
            storageStatus.isPermanentlyDenied) {
          print('[PermissionHelper] Permisos denegados permanentemente');
          await openAppSettings();
          return false;
        }

        return false;
      }
      // Android 10 y anteriores (API < 30): Usar storage tradicional
      else {
        print('[PermissionHelper] Android 10 o anterior detectado');

        if (await Permission.storage.isGranted) {
          print('[PermissionHelper] Storage permission ya concedido');
          return true;
        }

        final status = await Permission.storage.request();

        if (status.isPermanentlyDenied) {
          print(
            '[PermissionHelper] Storage permission denegado permanentemente',
          );
          await openAppSettings();
          return false;
        }

        return status.isGranted;
      }
    } catch (e) {
      print('[PermissionHelper] Error al solicitar permisos: $e');
      return false;
    }
  }

  /// Obtener la versión de Android SDK
  static Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;

    try {
      // Usar device_info_plus si está disponible, sino asumir versión moderna
      // Por ahora, usaremos un método simple basado en el comportamiento de los permisos

      // Intentar verificar si los permisos granulares están disponibles
      final hasGranularPermissions = await Permission.audio.status;
      // Si el permiso audio existe y no es "restricted", estamos en Android 13+
      if (hasGranularPermissions != PermissionStatus.restricted) {
        // Verificar si manageExternalStorage está disponible
        final hasManage = await Permission.manageExternalStorage.status;
        if (hasManage != PermissionStatus.restricted) {
          // Probablemente Android 11+
          // Intentar detectar si es 13+ verificando si storage está deprecado
          return 33; // Asumir Android 13+ si audio está disponible
        }
        return 30; // Android 11-12
      }
      return 29; // Android 10 o anterior
    } catch (e) {
      print('[PermissionHelper] Error detectando versión de Android: $e');
      // En caso de error, asumir Android moderno para usar permisos más seguros
      return 33;
    }
  }
}
