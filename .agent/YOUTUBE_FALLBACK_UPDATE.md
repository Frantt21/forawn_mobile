# YouTube Fallback API Update

## Resumen de Cambios

Se ha actualizado el sistema de descarga de música para usar tu nueva API de Foranly como tercera opción de fallback, y se ha mejorado la conversión automática de Spotify a YouTube cuando las APIs de Spotify fallan.

## Orden de APIs para Descargas

### Para Spotify:
1. **Dorratz API** (`api.dorratz.com/spotifydl`) - Primera opción
2. **RapidAPI Spotify Downloader** - Segunda opción (fallback automático)
3. **YouTube Fallback** - Tercera opción (si ambas APIs de Spotify fallan)

### Para YouTube Fallback:
1. **Dorratz API** (`ytmp3.nu`) - Primera opción
2. **RapidAPI YouTube to MP3** - Segunda opción
3. **Foranly API** (`http://api.foranly.space:24725`) - **NUEVA** Tercera opción
4. **ClickAPI** (`https://clickapi.net/api/widgetplus`) - **NUEVA** Cuarta opción

## Cambios Realizados

### 1. `youtube_fallback_service.dart`

**Actualización del método `_getDownloadUrlFromApi`:**
- ✅ Removidas APIs no funcionales (loader.to, yt5s.io, cobalt.tools)
- ✅ Agregada Foranly API como tercera opción
- ✅ Agregada ClickAPI como cuarta opción
- ✅ Actualizado el orden: Dorratz → RapidAPI → Foranly → ClickAPI
- ✅ Timeout de 30 segundos para Foranly API
- ✅ Timeout de 25 segundos para ClickAPI
- ✅ Headers especiales para ClickAPI (Referer, Origin) para evitar error CORS


**Configuración de Foranly API:**
```dart
// OPCIÓN 3: Foranly API (ytdlp + ffmpeg)
final response = await http.post(
  Uri.parse('http://api.foranly.space:24725/download'),
  headers: {
    'Content-Type': 'application/json',
  },
  body: json.encode({
    'url': videoUrl,
    'format': 'mp3',
  }),
).timeout(const Duration(seconds: 30));
```

**Respuestas esperadas de Foranly API:**
- `{ "success": true, "downloadUrl": "..." }` 
- O alternativamente: `{ "url": "..." }`

### 2. `spotify_service.dart`

**Nuevo método `extractTrackInfo`:**
- ✅ Extrae información de track y artista desde SpotifyTrack
- ✅ Maneja casos donde el artista está en el título (formato "Artista - Canción")
- ✅ Proporciona datos limpios para búsqueda en YouTube

```dart
Map<String, String> extractTrackInfo(SpotifyTrack track) {
  String trackName = track.title.trim();
  String artistName = track.artists.trim();
  
  // Si no hay artista, intenta extraerlo del título
  if (artistName.isEmpty && trackName.contains(' - ')) {
    final parts = trackName.split(' - ');
    if (parts.length >= 2) {
      artistName = parts[0].trim();
      trackName = parts.sublist(1).join(' - ').trim();
    }
  }
  
  return {
    'trackName': trackName,
    'artistName': artistName,
  };
}
```

## Flujo de Descarga Completo

```
Usuario busca canción
    ↓
Búsqueda en Spotify (api.dorratz.com/spotifysearch)
    ↓
Usuario selecciona canción
    ↓
[INTENTO 1] Dorratz Spotify API
    ↓ (si falla)
[INTENTO 2] RapidAPI Spotify Downloader
    ↓ (si falla)
[INTENTO 3] YouTube Fallback
    ↓
    [3.1] Buscar video en YouTube (youtube_explode_dart)
    ↓
    [3.2] Intentar Dorratz ytmp3.nu
    ↓ (si falla)
    [3.3] Intentar RapidAPI YouTube to MP3
    ↓ (si falla)
    [3.4] Intentar Foranly API ← NUEVA
    ↓
Descarga del archivo MP3
    ↓
Guardado en carpeta seleccionada (SAF)
```

## Conversión Spotify → YouTube

El sistema ya implementa conversión automática:

1. **Extracción de metadata**: Cuando Spotify falla, el sistema extrae:
   - Título de la canción
   - Nombre del artista
   
2. **Búsqueda en YouTube**: Usa estos datos para buscar:
   - Query: `"{artista} - {canción} official audio"`
   
3. **Descarga**: Una vez encontrado el video, intenta descargar usando las 3 APIs

## Configuración de la API de Foranly

### Endpoint
```
POST http://api.foranly.space:24725/download
```

### Headers
```json
{
  "Content-Type": "application/json"
}
```

### Body
```json
{
  "url": "https://www.youtube.com/watch?v=VIDEO_ID",
  "format": "mp3"
}
```

### Respuesta Esperada
```json
{
  "success": true,
  "downloadUrl": "http://api.foranly.space:24725/downloads/file.mp3"
}
```

}
```

O alternativamente:
```json
{
  "url": "http://api.foranly.space:24725/downloads/file.mp3"
}
```

## Configuración de ClickAPI

### Endpoint
```
GET https://clickapi.net/api/widgetplus?url={YOUTUBE_URL}
```

### Headers Requeridos
```json
{
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "Referer": "https://clickapi.net/",
  "Origin": "https://clickapi.net",
  "Accept": "application/json, text/plain, */*",
  "Accept-Language": "es-ES,es;q=0.9,en;q=0.8"
}
```

**⚠️ Importante**: Los headers `Referer` y `Origin` son **obligatorios** para evitar el error:
```
Sandbox, or No referer policy not allowed.
```

### Respuesta Esperada
ClickAPI puede devolver diferentes estructuras. El código busca la URL en estos campos:
- `data['url']`
- `data['downloadUrl']`
- `data['link']`
- `data['audio']['url']`
- `data['formats'][n]['url']` (para formato MP3 o con audio)

Ejemplo de respuesta:
```json
{
  "url": "https://clickapi.net/downloads/file.mp3"
}
```

## Características del Sistema

✅ **Fallback automático**: Si una API falla, intenta la siguiente
✅ **Conversión Spotify → YouTube**: Automática cuando Spotify no está disponible
✅ **Timeout configurado**: 30 segundos para Foranly API, 25 segundos para ClickAPI
✅ **Logs detallados**: Para debugging y monitoreo
✅ **Manejo de errores**: Cada API tiene su propio try-catch
✅ **Progreso de descarga**: Reporta progreso en tiempo real
✅ **Headers CORS**: ClickAPI incluye headers necesarios para evitar restricciones

## Logs de Ejemplo

```
[SpotifyService] Intentando Dorratz API...
[SpotifyService] Dorratz falló: ...
[SpotifyService] Intentando RapidAPI como fallback...
[SpotifyService] RapidAPI falló: ...
[DownloadService] Activando fallback de YouTube...
[YoutubeFallback] Buscando en YouTube: "Artista - Canción official audio"
[YoutubeFallback] Video encontrado: ...
[YoutubeFallback] [1/4] Intentando Dorratz API...
[YoutubeFallback] Dorratz API falló: ...
[YoutubeFallback] [2/4] Intentando RapidAPI...
[YoutubeFallback] RapidAPI falló: ...
[YoutubeFallback] [3/4] Intentando Foranly API...
[YoutubeFallback] Foranly API falló: ...
[YoutubeFallback] [4/4] Intentando ClickAPI...
[YoutubeFallback] ClickAPI status: 200
[YoutubeFallback] ✓ ClickAPI OK
[YoutubeFallback] Descargando desde: https://clickapi.net/downloads/...
[YoutubeFallback] ✓ Completo: 3.45 MB
```

## Testing

Para probar el nuevo sistema:

1. Busca una canción en la app
2. Intenta descargarla
3. Observa los logs en la consola
4. Verifica que la descarga se complete exitosamente

Si las primeras APIs fallan, deberías ver:
```
[YoutubeFallback] [4/4] Intentando ClickAPI...
[YoutubeFallback] ✓ ClickAPI OK
```

## Notas Importantes

### Foranly API
- La API de Foranly debe estar corriendo en `http://api.foranly.space:24725`
- El endpoint debe ser `/download` y aceptar POST requests
- La respuesta debe incluir `downloadUrl` o `url` con la URL del archivo MP3
- El timeout es de 30 segundos (configurable en el código)
- La API debe soportar formato JSON tanto en request como en response

### ClickAPI
- Requiere headers `Referer` y `Origin` para funcionar
- Sin estos headers, devuelve: "Sandbox, or No referer policy not allowed"
- El timeout es de 25 segundos
- Puede devolver diferentes estructuras de respuesta (el código maneja múltiples formatos)
- Es la última opción de fallback (cuarta)
