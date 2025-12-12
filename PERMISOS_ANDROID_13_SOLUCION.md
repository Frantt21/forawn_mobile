# Solución de Permisos para Android 13+

## Problema Identificado

La aplicación funcionaba correctamente en Android 10 y 11, pero en Android 13+ (API 33+) no solicitaba los permisos de almacenamiento correctamente. Esto se debía a que:

1. **Permisos deprecados**: Se estaba usando `Permission.storage` que está deprecado en Android 13+
2. **Falta de permisos granulares**: Android 13+ requiere permisos específicos como `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO`
3. **Configuración incorrecta del AndroidManifest**: No se limitaban los permisos antiguos solo a versiones antiguas de Android

## Cambios Realizados

### 1. AndroidManifest.xml

Se actualizó la configuración de permisos para soportar todas las versiones de Android (10-15):

```xml
<!-- Permisos para Android 12 y anteriores (API <= 32) -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" 
    android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" 
    android:maxSdkVersion="32"/>

<!-- Permisos granulares para Android 13+ (API 33+) -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>

<!-- Permiso especial para acceso completo al almacenamiento -->
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"
    tools:ignore="ScopedStorage"/>
```

### 2. Nuevo Helper Centralizado: `permission_helper.dart`

Se creó un helper centralizado para manejar permisos de manera consistente en toda la app:

**Ubicación**: `lib/services/permission_helper.dart`

**Funcionalidad**:
- Detecta automáticamente la versión de Android
- Solicita los permisos correctos según la versión:
  - **Android 13+ (API 33+)**: Permisos granulares (audio, photos, videos) + MANAGE_EXTERNAL_STORAGE
  - **Android 11-12 (API 30-32)**: MANAGE_EXTERNAL_STORAGE + storage tradicional
  - **Android 10 y anteriores (API < 30)**: Storage tradicional
- Maneja permisos denegados permanentemente abriendo la configuración de la app

### 3. Archivos Actualizados

Se actualizaron los siguientes archivos para usar el nuevo `PermissionHelper`:

1. **`lib/services/download_service.dart`**: Servicio de descarga
2. **`lib/screens/qr_generator_screen.dart`**: Pantalla de generador QR
3. **`lib/screens/images_ia_screen.dart`**: Pantalla de imágenes IA
4. **`lib/screens/downloads_screen.dart`**: Pantalla de descargas

Todos ahora usan:
```dart
import '../services/permission_helper.dart';

Future<bool> _requestStoragePermission() async {
  return await PermissionHelper.requestStoragePermission();
}
```

## Cómo Funciona

### Flujo de Solicitud de Permisos

1. **Detección de versión**: El helper detecta la versión de Android del dispositivo
2. **Solicitud de permisos**:
   - En Android 13+, solicita primero permisos granulares (audio, photos, videos)
   - Si el usuario los rechaza, intenta solicitar MANAGE_EXTERNAL_STORAGE
   - En versiones anteriores, usa el flujo tradicional
3. **Manejo de rechazo**: Si el usuario rechaza permanentemente, abre la configuración de la app

### Ejemplo de Uso

```dart
// En cualquier pantalla o servicio
final hasPermission = await PermissionHelper.requestStoragePermission();
if (!hasPermission) {
  // Mostrar mensaje al usuario
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Se necesitan permisos de almacenamiento')),
  );
  return;
}

// Continuar con la operación de archivo
```

## Compatibilidad

✅ **Android 10 (API 29)**: Storage tradicional
✅ **Android 11 (API 30)**: MANAGE_EXTERNAL_STORAGE + Storage
✅ **Android 12 (API 31-32)**: MANAGE_EXTERNAL_STORAGE + Storage
✅ **Android 13 (API 33)**: Permisos granulares + MANAGE_EXTERNAL_STORAGE
✅ **Android 14 (API 34)**: Permisos granulares + MANAGE_EXTERNAL_STORAGE
✅ **Android 15 (API 35)**: Permisos granulares + MANAGE_EXTERNAL_STORAGE

## Próximos Pasos

1. **Probar en dispositivos reales** con Android 13, 14 y 15
2. **Verificar que los permisos se soliciten correctamente** en cada versión
3. **Probar el flujo de rechazo permanente** para asegurar que se abre la configuración correctamente

## Notas Importantes

- **MANAGE_EXTERNAL_STORAGE** es un permiso especial que requiere aprobación manual del usuario en la configuración
- Los permisos granulares (READ_MEDIA_*) son más restrictivos pero más seguros
- La app ahora solicita múltiples permisos para asegurar compatibilidad máxima
- El helper maneja automáticamente todos los casos edge (permisos denegados, permanentemente denegados, etc.)
