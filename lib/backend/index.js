// server.js
const express = require('express');
require('dotenv').config();
const cors = require('cors');
const { exec, spawn, spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const https = require('https');
const http = require('http');
const SpotifyWebApi = require('spotify-web-api-node');
const CacheDatabase = require('./database_supabase');
const GoogleDriveService = require('./google_drive');
const YouTubeSearchService = require('./youtube_search');

const app = express();
const PORT = 24725;

const TOOLS_DIR = path.join(__dirname, 'tools');
const TEMP_DIR = path.join(TOOLS_DIR, 'temp');

const ARCH = process.arch;
const IS_ARM = ARCH === 'arm64';

const YTDLP_URL = IS_ARM
  ? "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64"
  : "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";

const FFMPEG_URL = IS_ARM
  ? "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz"
  : "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz";

let YT_DLP_BINARY = null;
let FFMPEG_BINARY = null;

// Spotify API setup
const spotifyApi = new SpotifyWebApi({
  clientId: process.env.SPOTIFY_CLIENT_ID || 'TU_CLIENT_ID_AQUI',
  clientSecret: process.env.SPOTIFY_CLIENT_SECRET || 'TU_CLIENT_SECRET_AQUI'
});

// Metadata cache
const metadataCache = new Map();
const CACHE_DURATION = 24 * 60 * 60 * 1000; // 24 horas

// Initialize cache system
const cacheDB = new CacheDatabase();
const googleDrive = new GoogleDriveService();
const youtubeSearch = new YouTubeSearchService();
const CACHE_EXPIRATION_DAYS = parseInt(process.env.CACHE_EXPIRATION_DAYS) || 7;

// Authenticate Spotify on startup
async function authenticateSpotify() {
  try {
    const data = await spotifyApi.clientCredentialsGrant();
    spotifyApi.setAccessToken(data.body['access_token']);
    console.log('[SPOTIFY] Authenticated successfully');
    
    // Refresh token every 50 minutes
    setTimeout(authenticateSpotify, 50 * 60 * 1000);
  } catch (err) {
    console.error('[SPOTIFY] Authentication failed:', err);
    // Retry in 5 minutes
    setTimeout(authenticateSpotify, 5 * 60 * 1000);
  }
}

app.use(cors());
app.use(express.json());

function ensureDirs() {
  if (!fs.existsSync(TOOLS_DIR)) fs.mkdirSync(TOOLS_DIR, { recursive: true });
  if (!fs.existsSync(TEMP_DIR)) fs.mkdirSync(TEMP_DIR, { recursive: true });
}

function sanitizeFilename(name) {
  if (!name) return 'download';
  let s = name.replace(/[<>:"/\\|?*\x00-\x1F]/g, '').trim();
  s = s.replace(/\s+/g, ' ');
  if (s.length > 200) s = s.substring(0, 200).trim();
  return s || 'download';
}

function cleanupJob(jobDir) {
  try {
    if (fs.existsSync(jobDir)) {
      fs.rmSync(jobDir, { recursive: true, force: true });
      console.log(`[CLEANUP] removed ${jobDir}`);
    }
  } catch (e) {
    console.warn('[CLEANUP] failed:', e);
  }
}

async function downloadFile(url, destPath) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        return downloadFile(res.headers.location, destPath).then(resolve).catch(reject);
      }
      const file = fs.createWriteStream(destPath);
      res.pipe(file);
      file.on('finish', () => file.close(() => setTimeout(() => resolve(destPath), 300)));
      file.on('error', (err) => {
        try { fs.unlinkSync(destPath); } catch (_) {}
        reject(err);
      });
    });
    req.on('error', reject);
  });
}

// Search Spotify for metadata with cache
// Search Spotify for metadata with cache
async function searchSpotifyMetadata(title, artist) {
  const cacheKey = `${title.toLowerCase()}_${artist.toLowerCase()}`;
  
  // Verificar caché
  const cached = metadataCache.get(cacheKey);
  if (cached && (Date.now() - cached.timestamp < CACHE_DURATION)) {
    console.log('[SPOTIFY] Using cached metadata for:', title);
    return cached.data;
  }
  
  // Helper for single search attempt
  const performSearch = async (queryToUse) => {
      try {
        console.log('[SPOTIFY] Searching with query:', queryToUse);
        const result = await spotifyApi.searchTracks(queryToUse, { limit: 1 });
        if (result.body.tracks.items.length > 0) {
            return result.body.tracks.items[0];
        }
        return null;
      } catch (err) {
        if (err.statusCode === 429) {
            const retryAfter = err.headers?.['retry-after'] || 1;
            console.warn(`[SPOTIFY] Rate limited, waiting ${retryAfter}s`);
            await new Promise(resolve => setTimeout(resolve, retryAfter * 1000));
            return performSearch(queryToUse); // Recursive retry
        }
        console.error('[SPOTIFY] Search error for query:', queryToUse, err.message);
        return null;
      }
  };

  try {
    // Strategy 1: Original query (All artists)
    let query = artist ? `track:${title} artist:${artist}` : title;
    let track = await performSearch(query);

    // Strategy 2: First artist only (if multiple artists exist)
    if (!track && artist && (artist.includes(',') || artist.includes(';'))) {
        const firstArtist = artist.split(/[,;]/)[0].trim();
        console.log('[SPOTIFY] Strategy 1 failed. Trying Strategy 2: First artist only ->', firstArtist);
        query = `track:${title} artist:${firstArtist}`;
        track = await performSearch(query);
    }

     // Strategy 3: First two artists (if more than 2 artists exist)
    if (!track && artist && (artist.split(/[,;]/).length > 2)) {
         const parts = artist.split(/[,;]/);
         const firstTwoArtists = `${parts[0].trim()} ${parts[1].trim()}`; 
         // Note: Spotify search uses space as AND for artists usually, or we can just send them as string
         // Let's try sending "Artist1 Artist2" which often works for "Feat" scenarios
         console.log('[SPOTIFY] Strategy 2 failed. Trying Strategy 3: First two artists ->', firstTwoArtists);
         query = `track:${title} artist:${firstTwoArtists}`;
         track = await performSearch(query);
    }
    
    // Strategy 4: Title only (Last resort - be careful with accuracy, maybe skip?)
    // Skipping for now to avoid wrong matches.

    if (!track) {
      console.log('[SPOTIFY] No results found after all strategies for:', title);
      return null;
    }
    
    // Process found track
    const album = track.album;
    
    // Download album art
    let albumArtBuffer = null;
    let albumArtUrl = null;
    
    if (album.images && album.images.length > 0) {
      albumArtUrl = album.images[0].url; // Highest quality URL
      const imageUrl = album.images[0].url;
      try {
        albumArtBuffer = await new Promise((resolve, reject) => {
          https.get(imageUrl, (res) => {
            const chunks = [];
            res.on('data', chunk => chunks.push(chunk));
            res.on('end', () => resolve(Buffer.concat(chunks)));
            res.on('error', reject);
          }).on('error', reject);
        });
      } catch (err) {
        console.warn('[SPOTIFY] Failed to download album art:', err);
      }
    }
    
    const metadata = {
      title: track.name,
      artist: track.artists.map(a => a.name).join(', '),
      album: album.name,
      year: album.release_date ? album.release_date.split('-')[0] : undefined,
      trackNumber: track.track_number,
      albumArt: albumArtBuffer,
      albumArtUrl: albumArtUrl,
      isrc: track.external_ids?.isrc,
      spotifyUrl: track.external_urls.spotify,
      duration: Math.floor(track.duration_ms / 1000)
    };
    
    // Guardar en caché
    metadataCache.set(cacheKey, {
      data: metadata,
      timestamp: Date.now()
    });
    
    console.log('[SPOTIFY] Cached metadata for:', title, '- Cache size:', metadataCache.size);
    
    return metadata;
  } catch (err) {
    console.error('[SPOTIFY] Critical search error:', err);
    return null;
  }
}

// Trim silence from MP3 to match expected duration
async function trimSilenceToMatchDuration(filePath, expectedDurationSeconds) {
  try {
    if (!FFMPEG_BINARY || !expectedDurationSeconds) {
      return false;
    }

    console.log('[TRIM] Checking if silence trimming is needed...');
    console.log('[TRIM] Expected duration:', expectedDurationSeconds, 's');

    // Get actual duration using ffprobe
    const actualDuration = await new Promise((resolve, reject) => {
      exec(`"${FFMPEG_BINARY}" -i "${filePath}" 2>&1 | grep "Duration"`, (err, stdout) => {
        if (err && !stdout) {
          reject(err);
          return;
        }
        
        const match = stdout.match(/Duration: (\d{2}):(\d{2}):(\d{2}\.\d{2})/);
        if (match) {
          const hours = parseInt(match[1]);
          const minutes = parseInt(match[2]);
          const seconds = parseFloat(match[3]);
          resolve(hours * 3600 + minutes * 60 + seconds);
        } else {
          reject(new Error('Could not parse duration'));
        }
      });
    });

    console.log('[TRIM] Actual duration:', actualDuration.toFixed(2), 's');
    const difference = Math.abs(actualDuration - expectedDurationSeconds);
    console.log('[TRIM] Difference:', difference.toFixed(2), 's');

    // Only trim if difference is > 1 second
    if (difference < 1) {
      console.log('[TRIM] Difference too small, skipping trim');
      return false;
    }

    console.log('[TRIM] Trimming silence to match Spotify duration...');
    const trimmedPath = `${filePath}.trimmed.mp3`;

    // Use silenceremove filter to remove silence from start and end
    const args = [
      '-i', filePath,
      '-af', 'silenceremove=start_periods=1:start_duration=0.1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_duration=0.1:start_threshold=-50dB,areverse',
      '-c:a', 'libmp3lame',
      '-b:a', '192k',
      '-y', trimmedPath
    ];

    await new Promise((resolve, reject) => {
      exec(`"${FFMPEG_BINARY}" ${args.map(a => `"${a}"`).join(' ')}`, (err, stdout, stderr) => {
        if (err) {
          console.error('[TRIM] ffmpeg error:', err);
          reject(err);
        } else {
          console.log('[TRIM] Silence removed successfully');
          resolve();
        }
      });
    });

    // Replace original file
    if (fs.existsSync(trimmedPath)) {
      const trimmedSize = fs.statSync(trimmedPath).size;
      console.log('[TRIM] Trimmed file size:', trimmedSize, 'bytes');
      
      fs.unlinkSync(filePath);
      fs.renameSync(trimmedPath, filePath);
      console.log('[TRIM] ✓ File trimmed successfully');
      return true;
    }

    return false;
  } catch (err) {
    console.error('[TRIM] Error:', err);
    return false;
  }
}

// Calculate Levenshtein similarity between two strings (0.0 to 1.0)
function calculateSimilarity(str1, str2) {
  const s1 = str1.toLowerCase();
  const s2 = str2.toLowerCase();
  
  if (s1 === s2) return 1.0;
  if (s1.length === 0 || s2.length === 0) return 0.0;
  
  const matrix = [];
  for (let i = 0; i <= s2.length; i++) {
    matrix[i] = [i];
  }
  for (let j = 0; j <= s1.length; j++) {
    matrix[0][j] = j;
  }
  
  for (let i = 1; i <= s2.length; i++) {
    for (let j = 1; j <= s1.length; j++) {
      if (s2.charAt(i - 1) === s1.charAt(j - 1)) {
        matrix[i][j] = matrix[i - 1][j - 1];
      } else {
        matrix[i][j] = Math.min(
          matrix[i - 1][j - 1] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j] + 1
        );
      }
    }
  }
  
  const distance = matrix[s2.length][s1.length];
  const maxLength = Math.max(s1.length, s2.length);
  return 1.0 - (distance / maxLength);
}

// Validate Spotify metadata matches the search query
function validateMetadata(searchTitle, searchArtist, spotifyTitle, spotifyArtist) {
  const titleSimilarity = calculateSimilarity(searchTitle, spotifyTitle);
  const artistSimilarity = calculateSimilarity(searchArtist || '', spotifyArtist || '');
  
  const titleMatches = titleSimilarity > 0.4;
  const artistMatches = !searchArtist || artistSimilarity > 0.3;
  
  console.log('[VALIDATE] Title similarity:', (titleSimilarity * 100).toFixed(0) + '%', `("${searchTitle}" vs "${spotifyTitle}")`);
  if (searchArtist) {
    console.log('[VALIDATE] Artist similarity:', (artistSimilarity * 100).toFixed(0) + '%', `("${searchArtist}" vs "${spotifyArtist}")`);
  }
  
  return titleMatches && artistMatches;
}

// Write ID3 tags to MP3 file using ffmpeg
async function writeMetadataToFile(filePath, metadata) {
  try {
    if (!FFMPEG_BINARY) {
      console.error('[METADATA] ffmpeg not available');
      return false;
    }

    console.log('[METADATA] Starting metadata write for:', filePath);
    console.log('[METADATA] Metadata:', {
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      year: metadata.year,
      trackNumber: metadata.trackNumber,
      isrc: metadata.isrc,
      hasAlbumArt: !!metadata.albumArt
    });

    // Crear archivo temporal
    const tempPath = `${filePath}.temp.mp3`;
    
    // Construir argumentos de ffmpeg para metadatos
    const args = [
      '-i', filePath,
      '-c', 'copy',
      '-metadata', `title=${metadata.title}`,
      '-metadata', `artist=${metadata.artist}`,
      '-metadata', `album=${metadata.album}`,
    ];

    if (metadata.year) {
      args.push('-metadata', `date=${metadata.year}`);
    }
    if (metadata.trackNumber) {
      args.push('-metadata', `track=${metadata.trackNumber}`);
    }
    if (metadata.isrc) {
      args.push('-metadata', `isrc=${metadata.isrc}`);
    }
    if (metadata.spotifyUrl) {
      args.push('-metadata', `comment=Spotify: ${metadata.spotifyUrl}`);
    }

    args.push('-y', tempPath);

    console.log('[METADATA] Running ffmpeg with args:', args.join(' '));

    // Ejecutar ffmpeg para escribir metadatos
    const result = await new Promise((resolve, reject) => {
      exec(`"${FFMPEG_BINARY}" ${args.map(a => `"${a}"`).join(' ')}`, (err, stdout, stderr) => {
        if (err) {
          console.error('[METADATA] ffmpeg error:', err);
          console.error('[METADATA] ffmpeg stderr:', stderr);
          reject(err);
        } else {
          console.log('[METADATA] ffmpeg stdout:', stdout);
          console.log('[METADATA] ffmpeg stderr:', stderr);
          resolve({ stdout, stderr });
        }
      });
    });

    console.log('[METADATA] ffmpeg completed, checking temp file...');

    // Verificar que el archivo temporal se creó
    if (!fs.existsSync(tempPath)) {
      console.error('[METADATA] Temp file not created');
      return false;
    }

    const tempSize = fs.statSync(tempPath).size;
    console.log('[METADATA] Temp file size:', tempSize, 'bytes');

    // Reemplazar archivo original
    fs.unlinkSync(filePath);
    fs.renameSync(tempPath, filePath);
    console.log('[METADATA] Replaced original file with metadata-enriched version');

    // Si hay artwork, agregarlo en un segundo paso
    if (metadata.albumArt) {
      console.log('[METADATA] Adding album artwork...');
      
      // Detectar si es WebP (los primeros bytes son 'RIFF....WEBP')
      const isWebP = metadata.albumArt.length > 12 && 
                     metadata.albumArt.toString('ascii', 0, 4) === 'RIFF' &&
                     metadata.albumArt.toString('ascii', 8, 12) === 'WEBP';
      
      let artworkPath = `${filePath}.jpg`;
      
      if (isWebP) {
        console.log('[METADATA] Detected WebP format, converting to JPEG...');
        const webpPath = `${filePath}.webp`;
        fs.writeFileSync(webpPath, metadata.albumArt);
        
        // Convertir WebP a JPEG cuadrado (1:1) centrado usando ffmpeg
        const convertArgs = [
          '-i', webpPath,
          '-vf', 'crop=min(iw\\,ih):min(iw\\,ih)', // Recortar al cuadrado centrado
          '-q:v', '2', // Calidad JPEG (2 = alta calidad)
          '-y', artworkPath
        ];
        
        try {
          await new Promise((resolve, reject) => {
            exec(`"${FFMPEG_BINARY}" ${convertArgs.map(a => `"${a}"`).join(' ')}`, (err, stdout, stderr) => {
              if (err) {
                console.error('[METADATA] WebP conversion error:', err);
                reject(err);
              } else {
                console.log('[METADATA] WebP converted to square JPEG successfully');
                resolve({ stdout, stderr });
              }
            });
          });
          
          // Limpiar archivo WebP temporal
          if (fs.existsSync(webpPath)) {
            fs.unlinkSync(webpPath);
          }
        } catch (convErr) {
          console.error('[METADATA] Failed to convert WebP, skipping artwork');
          if (fs.existsSync(webpPath)) fs.unlinkSync(webpPath);
          if (fs.existsSync(artworkPath)) fs.unlinkSync(artworkPath);
          return true; // Continuar sin artwork
        }
      } else {
        // Es JPEG/PNG, recortar a cuadrado
        console.log('[METADATA] Processing image to square format...');
        const tempImagePath = `${filePath}.temp.jpg`;
        fs.writeFileSync(tempImagePath, metadata.albumArt);
        
        // Recortar a cuadrado centrado
        const cropArgs = [
          '-i', tempImagePath,
          '-vf', 'crop=min(iw\\,ih):min(iw\\,ih)', // Recortar al cuadrado centrado
          '-q:v', '2',
          '-y', artworkPath
        ];
        
        try {
          await new Promise((resolve, reject) => {
            exec(`"${FFMPEG_BINARY}" ${cropArgs.map(a => `"${a}"`).join(' ')}`, (err, stdout, stderr) => {
              if (err) {
                console.error('[METADATA] Image crop error:', err);
                // Si falla el recorte, usar imagen original
                fs.copyFileSync(tempImagePath, artworkPath);
                resolve({ stdout, stderr });
              } else {
                console.log('[METADATA] Image cropped to square successfully');
                resolve({ stdout, stderr });
              }
            });
          });
          
          // Limpiar archivo temporal
          if (fs.existsSync(tempImagePath)) {
            fs.unlinkSync(tempImagePath);
          }
        } catch (cropErr) {
          console.error('[METADATA] Failed to crop image, using original');
          if (fs.existsSync(tempImagePath)) {
            fs.copyFileSync(tempImagePath, artworkPath);
            fs.unlinkSync(tempImagePath);
          }
        }
      }

      const tempPath2 = `${filePath}.temp2.mp3`;
      const artArgs = [
        '-i', filePath,
        '-i', artworkPath,
        '-map', '0:0',
        '-map', '1:0',
        '-c', 'copy',
        '-id3v2_version', '3',
        '-metadata:s:v', 'title=Album cover',
        '-metadata:s:v', 'comment=Cover (front)',
        '-y', tempPath2
      ];

      console.log('[METADATA] Running ffmpeg for artwork:', artArgs.join(' '));

      await new Promise((resolve, reject) => {
        exec(`"${FFMPEG_BINARY}" ${artArgs.map(a => `"${a}"`).join(' ')}`, (err, stdout, stderr) => {
          if (err) {
            console.error('[METADATA] ffmpeg artwork error:', err);
            console.error('[METADATA] ffmpeg artwork stderr:', stderr);
            reject(err);
          } else {
            console.log('[METADATA] ffmpeg artwork completed');
            resolve({ stdout, stderr });
          }
        });
      });

      if (fs.existsSync(tempPath2)) {
        const artSize = fs.statSync(tempPath2).size;
        console.log('[METADATA] Artwork file size:', artSize, 'bytes');
        
        fs.unlinkSync(filePath);
        fs.renameSync(tempPath2, filePath);
        console.log('[METADATA] Replaced file with artwork-enriched version');
      }

      // Limpiar archivo temporal de artwork
      try {
        if (fs.existsSync(artworkPath)) {
          fs.unlinkSync(artworkPath);
        }
      } catch (e) {
        console.warn('[METADATA] Could not delete artwork temp file:', e);
      }
    }

    const finalSize = fs.statSync(filePath).size;
    console.log('[METADATA] Final file size:', finalSize, 'bytes');
    console.log('[METADATA] ✓ Metadata written successfully');
    return true;
  } catch (err) {
    console.error('[METADATA] Write error:', err);
    console.error('[METADATA] Stack trace:', err.stack);
    
    // Limpiar archivos temporales en caso de error
    try {
      const tempPath = `${filePath}.temp.mp3`;
      const tempPath2 = `${filePath}.temp2.mp3`;
      const artworkPath = `${filePath}.jpg`;
      
      if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
      if (fs.existsSync(tempPath2)) fs.unlinkSync(tempPath2);
      if (fs.existsSync(artworkPath)) fs.unlinkSync(artworkPath);
    } catch (cleanupErr) {
      console.warn('[METADATA] Cleanup error:', cleanupErr);
    }
    
    return false;
  }
}

// Parse YouTube title to extract artist and song
function parseYouTubeTitle(title) {
  let artist = '';
  let song = title;
  
  // 1. Limpieza inicial agresiva de basura común (Official Video, 4K, Live, etc.)
  // Usamos regex genérico para capturar variaciones como (Video Oficial), [Official Audio], (Live at X)
  song = song.replace(/[(\[]\s*(?:official|video|audio|lyrics?|letra|visualizer|hd|4k|8k|3d|live|vivo|studio|sesión|session|prod\.|produced)\s*(?:oficial|lyric|video|audio|by)?.*?[)\]]/gi, '')
             .replace(/[(\[]\s*360°?\s*visualizer\s*[)\]]/gi, '') // El caso específico que pediste
             .replace(/\s*-\s*Topic\s*$/i, '') // Remove Topic suffix immediately
             .trim();
  
  let foundSep = false;
  
  // 2. Estrategia de Separación (Hierarchy of separators)
  // Probamos separadores comunes. Si encontramos " - ", asumimos que es el divisor principal.
  const separators = [' - ', ' : ', ' | ', ' /// ', ' // '];
  
  for (const sep of separators) {
    if (song.includes(sep)) {
      const parts = song.split(sep);
      // Heurística: Si hay varios separadores, usualmente el primero divide Artista - Canción
      if (parts.length >= 2) {
        artist = parts[0].trim();
        song = parts.slice(1).join(sep).trim(); // Unir el resto por si acaso
        foundSep = true;
        break; 
      }
    }
  }
  
  // Fallback: "Song by Artist"
  if (!foundSep && song.toLowerCase().includes(' by ')) {
    const parts = song.split(/\s+by\s+/i);
    if (parts.length >= 2) {
      song = parts[0].trim();
      artist = parts[1].trim();
      foundSep = true;
    }
  }
  
  // 3. Limpieza Secundaria del Título (CRÍTICO para "Tarot | Un Verano Sin Ti")
  // A veces el título extraído aún tiene basura como el nombre del álbum separado por | o //
  if (song) {
    // Si quedan pipes o slashes en el título, cortamos
    if (song.includes('|')) song = song.split('|')[0].trim();
    if (song.includes('//')) song = song.split('//')[0].trim();
    if (song.includes('///')) song = song.split('///')[0].trim();
    
    // Eliminar featurings del título (ej: "Song Name (feat. X)") -> "Song Name"
    // Esto ayuda a Spotify a encontrar la canción base más fácil
    song = song.replace(/\s*[(]?\s*(?:ft\.?|feat\.?|featuring|with|con)\s+.*?[)]?$/i, '');
    
    // Eliminar info de Remix/Version si está en paréntesis al final, para búsqueda más limpia
    // Opcional: a veces quieres el remix. Pero para "match" base, mejor quitarlo.
    song = song.replace(/[(\[]\s*(?:remix|mix|edit|version|ver|remaster|remastered).*?[)\]]/gi, '').trim();
  }
  
  // 4. Limpieza del Artista
  if (artist) {
    // Quedarse solo con el primer artista si hay featurings en el nombre del artista
    // Ej: "Bad Bunny (ft. Jhay Cortez)" -> "Bad Bunny"
    artist = artist.split(/\s*[(]?\s*(?:ft\.?|feat\.?|featuring|with|con|x|&)\s+/i)[0].trim();
  }
  
  return { artist, song };
}

async function setupEnvironment() {
  console.log('[INIT] checking environment...');
  ensureDirs();

  const archMarkerPath = path.join(TOOLS_DIR, `.arch_${ARCH}`);
  const reinstall = !fs.existsSync(archMarkerPath);
  if (reinstall) {
    try {
      for (const f of ['yt-dlp', 'yt-dlp.exe', 'ffmpeg', 'ffmpeg.tar.xz']) {
        const p = path.join(TOOLS_DIR, f);
        if (fs.existsSync(p)) fs.unlinkSync(p);
      }
      for (const f of fs.readdirSync(TOOLS_DIR)) {
        if (f.startsWith('ffmpeg-') && fs.statSync(path.join(TOOLS_DIR, f)).isDirectory()) {
          fs.rmSync(path.join(TOOLS_DIR, f), { recursive: true, force: true });
        }
      }
      fs.writeFileSync(archMarkerPath, 'ok');
    } catch (e) { console.warn('[INIT] cleanup warning:', e); }
  }

  const ytdlpPath = path.join(TOOLS_DIR, process.platform === 'win32' ? 'yt-dlp.exe' : 'yt-dlp');
  if (fs.existsSync(ytdlpPath)) {
    YT_DLP_BINARY = ytdlpPath;
  } else {
    try {
      await downloadFile(YTDLP_URL, ytdlpPath);
      fs.chmodSync(ytdlpPath, 0o755);
      YT_DLP_BINARY = ytdlpPath;
    } catch (e) {
      console.error('[INIT] yt-dlp download failed:', e);
    }
  }

  const localFfmpeg = path.join(TOOLS_DIR, 'ffmpeg', process.platform === 'win32' ? 'bin' : '', process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
  const systemCandidates = [localFfmpeg, '/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', 'ffmpeg'];
  FFMPEG_BINARY = systemCandidates.find(p => {
    try {
      if (p === 'ffmpeg') {
        const which = spawnSync('which', ['ffmpeg']);
        return which.status === 0 && which.stdout.toString().trim().length > 0;
      }
      return fs.existsSync(p);
    } catch (_) { return false; }
  });

  if (!FFMPEG_BINARY) {
    const tarPath = path.join(TOOLS_DIR, 'ffmpeg.tar.xz');
    try {
      await downloadFile(FFMPEG_URL, tarPath);
      await new Promise((resolve, reject) => {
        exec(`tar -xvf "${tarPath}" -C "${TOOLS_DIR}"`, (err) => err ? reject(err) : resolve());
      });
      const dir = fs.readdirSync(TOOLS_DIR).find(f => f.startsWith('ffmpeg-') && fs.statSync(path.join(TOOLS_DIR, f)).isDirectory());
      if (dir) {
        const extracted = path.join(TOOLS_DIR, dir, 'ffmpeg');
        const finalPath = path.join(TOOLS_DIR, 'ffmpeg');
        if (fs.existsSync(extracted)) {
          try { fs.renameSync(extracted, finalPath); } catch (_) { fs.copyFileSync(extracted, finalPath); }
          fs.chmodSync(finalPath, 0o755);
          FFMPEG_BINARY = finalPath;
        }
      }
      try { fs.unlinkSync(tarPath); } catch (_) {}
    } catch (e) {
      console.error('[INIT] ffmpeg setup failed:', e);
    }
  }

  console.log('[INIT] yt-dlp:', YT_DLP_BINARY);
  console.log('[INIT] ffmpeg:', FFMPEG_BINARY);
  
  // Authenticate Spotify
  await authenticateSpotify();
}
setupEnvironment().catch(err => console.error('[INIT] setup error', err));

// Progress store
const progressMap = new Map();

app.get('/', (req, res) => {
  res.json({ 
    status: 'ok', 
    tools: { 
      ytdlp: !!YT_DLP_BINARY, 
      ffmpeg: !!FFMPEG_BINARY, 
      spotify: !!spotifyApi.getAccessToken() 
    },
    cache: {
      size: metadataCache.size,
      duration: `${CACHE_DURATION / 1000 / 60 / 60}h`
    }
  });
});

// Get metadata from Spotify
app.get('/metadata', async (req, res) => {
  const title = req.query.title;
  const artist = req.query.artist || '';
  
  if (!title) {
    return res.status(400).json({ error: 'title parameter required' });
  }
  
  try {
    const metadata = await searchSpotifyMetadata(title, artist);
    if (!metadata) {
      return res.status(404).json({ error: 'No metadata found' });
    }
    
    // Don't send album art buffer in response (too large)
    const response = { ...metadata };
    delete response.albumArt;
    response.hasAlbumArt = !!metadata.albumArt;
    
    res.json(response);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Clear metadata cache
app.post('/clear-cache', (req, res) => {
  const size = metadataCache.size;
  metadataCache.clear();
  console.log('[CACHE] Cleared', size, 'entries');
  res.json({ cleared: size, message: 'Cache cleared successfully' });
});

// YouTube search endpoint
app.get('/youtube/search', async (req, res) => {
  const query = req.query.q || req.query.query;
  const limit = parseInt(req.query.limit) || 40; // Default changed to 40

  if (!query) {
    return res.status(400).json({ error: 'query parameter required' });
  }

  try {
    const results = await youtubeSearch.searchAndParse(query, limit);
    res.json({
      query: query,
      count: results.length,
      results: results
    });
  } catch (err) {
    console.error('[YOUTUBE] Search error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Endpoint to fetch metadata only (for manual tagging)
app.get('/metadata/search', async (req, res) => {
  const title = req.query.title;
  const artist = req.query.artist;
  
   if (!title) {
    return res.status(400).json({ error: 'title parameter required' });
  }
  
  try {
      // Reuse searchSpotifyMetadata logic
      const metadata = await searchSpotifyMetadata(title, artist || '');
      if (metadata) {
          res.json(metadata);
      } else {
          res.status(404).json({ error: 'Metadata not found' });
      }
  } catch (err) {
      console.error('[METADATA-SEARCH] Error:', err);
      res.status(500).json({ error: err.message });
  }
});

// Check if song is in cache
app.get('/cache/check', async (req, res) => {
  const title = req.query.title;
  const artist = req.query.artist || '';

  if (!title) {
    return res.status(400).json({ error: 'title parameter required' });
  }

  try {
    const cachedSong = await cacheDB.getSong(title, artist);
    
    if (cachedSong) {
      // Verify file still exists in Google Drive
      const exists = await googleDrive.fileExists(cachedSong.google_drive_id);
      
      if (exists) {
        return res.json({
          cached: true,
          downloadUrl: cachedSong.google_drive_url,
          metadata: {
            title: cachedSong.title,
            artist: cachedSong.artist,
            album: cachedSong.album,
            duration: cachedSong.duration,
            thumbnailUrl: cachedSong.thumbnail_url,
            lyrics: cachedSong.lyrics
          },
          cacheInfo: {
            createdAt: cachedSong.created_at,
            lastAccessed: cachedSong.last_accessed,
            accessCount: cachedSong.access_count
          }
        });
      } else {
        // File doesn't exist anymore, remove from cache
        console.log('[CACHE] File not found in Drive, removing from DB');
        // We'll handle this in cleanup
      }
    }

    res.json({ cached: false });
  } catch (err) {
    console.error('[CACHE] Check error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Get cache statistics
app.get('/cache/stats', async (req, res) => {
  try {
    const dbStats = await cacheDB.getStats();
    
    res.json({
      database: dbStats,
      expirationDays: CACHE_EXPIRATION_DAYS
    });
  } catch (err) {
    console.error('[CACHE] Stats error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Manual cache cleanup
app.post('/cache/cleanup', async (req, res) => {
  try {
    const oldSongs = await cacheDB.cleanupOldSongs(CACHE_EXPIRATION_DAYS);
    
    if (oldSongs.length > 0) {
      // Delete files from Google Drive
      const driveIds = oldSongs.map(s => s.google_drive_id);
      const deleteResults = await googleDrive.deleteFiles(driveIds);
      
      res.json({
        cleaned: oldSongs.length,
        songs: oldSongs.map(s => `${s.title} by ${s.artist}`),
        driveDeleteResults: deleteResults
      });
    } else {
      res.json({
        cleaned: 0,
        message: 'No old songs to clean up'
      });
    }
  } catch (err) {
    console.error('[CACHE] Cleanup error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Google Drive OAuth setup endpoints
app.get('/gdrive/auth-url', (req, res) => {
  try {
    const authUrl = googleDrive.getAuthUrl();
    res.json({ authUrl });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/oauth2callback', async (req, res) => {
  const code = req.query.code;
  
  if (!code) {
    return res.status(400).send('No authorization code provided');
  }

  try {
    const tokens = await googleDrive.getTokensFromCode(code);
    res.send(`
      <h1>Authorization Successful!</h1>
      <p>Add this to your .env file:</p>
      <pre>GOOGLE_DRIVE_REFRESH_TOKEN=${tokens.refresh_token}</pre>
      <p>You can close this window now.</p>
    `);
  } catch (err) {
    res.status(500).send(`Error: ${err.message}`);
  }
});

// Google Drive storage quota
app.get('/gdrive/quota', async (req, res) => {
  try {
    const quota = await googleDrive.getStorageQuota();
    res.json(quota);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// SSE progress
app.get('/progress/:jobId', (req, res) => {
  const jobId = req.params.jobId;
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
  res.write('data: {"status":"connected"}\n\n');
  const interval = setInterval(() => {
    const p = progressMap.get(jobId);
    if (p) {
      res.write(`data: ${JSON.stringify(p)}\n\n`);
      if (p.status === 'complete' || p.status === 'error') {
        clearInterval(interval);
        setTimeout(() => { progressMap.delete(jobId); res.end(); }, 1000);
      }
    }
  }, 500);
  req.on('close', () => clearInterval(interval));
});

// Start job
app.get('/download', async (req, res) => {
  const videoUrl = (req.query.url || '').toString();
  const format = (req.query.format || 'best').toString();
  const enrichMetadata = req.query.enrich === 'true';
  const providedTitle = req.query.title || '';
  const providedArtist = req.query.artist || '';
  
  if (!videoUrl) return res.status(400).json({ error: 'url parameter required' });
  if (!YT_DLP_BINARY) return res.status(503).json({ error: 'yt-dlp not available yet' });

  const cookiesPath = path.join(TOOLS_DIR, 'cookies.txt');
  const cookiesArgs = fs.existsSync(cookiesPath) ? ['--cookies', cookiesPath] : [];

  const runId = `${Date.now()}${Math.random().toString(36).slice(2, 9)}`;
  const jobDir = path.join(TEMP_DIR, runId);
  try { fs.mkdirSync(jobDir, { recursive: true }); } catch (e) { console.error('[JOB] mkdir error', e); }

  const outputTemplate = path.join(jobDir, `${runId}.%(ext)s`);
  const args = [
    '--output', outputTemplate,
    '--no-playlist',
    '--newline',
    ...cookiesArgs,
    '--js-runtimes', 'node',
    videoUrl
  ];

  if (format === 'audio' && FFMPEG_BINARY) {
    args.push('--extract-audio', '--audio-format', 'mp3', '--ffmpeg-location', FFMPEG_BINARY);
    // No agregamos metadata/thumbnail de yt-dlp porque lo haremos con Spotify después
  } else {
    args.push('-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best');
    if (FFMPEG_BINARY) args.push('--merge-output-format', 'mp4', '--ffmpeg-location', FFMPEG_BINARY);
  }

  progressMap.set(runId, { status: 'starting', progress: 0 });
  res.json({ jobId: runId, status: 'started' });

  let videoTitle = 'download';
  let parsedArtist = '';
  let parsedSong = '';
  let youtubeThumbnailUrl = '';
  
  // Siempre intentar obtener el título de YouTube para el nombre del archivo
  try {
    const metaArgs = ['-J', '--no-playlist', ...cookiesArgs, videoUrl];
    const meta = spawnSync(YT_DLP_BINARY, metaArgs, { encoding: 'utf8', timeout: 20000 });
    if (meta.status === 0 && meta.stdout) {
      const json = JSON.parse(meta.stdout);
      const title = json.title || (Array.isArray(json.entries) && json.entries[0]?.title) || '';
      videoTitle = sanitizeFilename(title || 'download');
      
      // Obtener thumbnail URL (maxresdefault > hqdefault > default)
      youtubeThumbnailUrl = json.thumbnail || 
                           (json.thumbnails && json.thumbnails[json.thumbnails.length - 1]?.url) ||
                           `https://img.youtube.com/vi/${json.id}/maxresdefault.jpg`;
      console.log('[THUMBNAIL] YouTube thumbnail URL:', youtubeThumbnailUrl);
      
      // Parsear título de YouTube solo si no hay valores proporcionados
      if (!providedTitle && !providedArtist) {
        const parsed = parseYouTubeTitle(title);
        parsedArtist = parsed.artist;
        parsedSong = parsed.song;
        console.log('[PARSE] Artist:', parsedArtist, 'Song:', parsedSong);
      }
    } else {
      console.warn('[META] failed to get JSON title, status:', meta.status);
    }
  } catch (e) {
    console.warn('[META] error:', e?.message || e);
  }

  // SIEMPRE priorizar valores proporcionados por la app
  if (providedTitle) {
    parsedSong = providedTitle;
    console.log('[PROVIDED] Using app-provided title:', parsedSong);
  }
  if (providedArtist) {
    parsedArtist = providedArtist;
    console.log('[PROVIDED] Using app-provided artist:', parsedArtist);
  }

  // Si tenemos ambos valores (ya sea de la app o parseados), actualizar videoTitle
  if (parsedSong && parsedArtist) {
    videoTitle = sanitizeFilename(`${parsedArtist} - ${parsedSong}`);
    console.log('[METADATA] Will search Spotify for:', parsedSong, 'by', parsedArtist);
  }

  const percentRegex = /\[download\].*?(\d{1,3}(?:\.\d+)?)%\s+of\s+([\d.]+\w+)\s+at\s+([\d.]+(?:[KMGT]?i?B)\/s)(?:\s+ETA\s+([0-9:]+))?/i;
  const simplePercent = /\[download\].*?(\d{1,3}(?:\.\d+)?)%/i;
  const mergingRegex = /\[Merger\]|\bmerg(?:ing|er)\b/i;

  let child;
  try {
    child = spawn(YT_DLP_BINARY, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    progressMap.set(runId, { status: 'error', message: 'Failed to start yt-dlp' });
    cleanupJob(jobDir);
    return;
  }

  function parseProgress(line) {
    let m = percentRegex.exec(line);
    if (m) {
      progressMap.set(runId, { status: 'downloading', progress: parseFloat(m[1]), size: m[2], speed: m[3], eta: m[4] || 'Unknown' });
      return;
    }
    m = simplePercent.exec(line);
    if (m) {
      progressMap.set(runId, { status: 'downloading', progress: parseFloat(m[1]) });
      return;
    }
    if (mergingRegex.test(line)) {
      progressMap.set(runId, { status: 'merging', progress: 95 });
    }
  }

  child.stdout.on('data', d => {
    const line = d.toString().trim();
    console.log(`[YT-DLP ${runId}] ${line}`);
    parseProgress(line);
  });
  child.stderr.on('data', d => {
    const line = d.toString().trim();
    console.log(`[YT-DLP ${runId}] ${line}`);
    parseProgress(line);
  });

  child.on('close', async () => {
    try {
      const files = fs.readdirSync(jobDir);
      let candidate = files.find(f => f.startsWith(runId) && !f.endsWith('.part'));
      if (!candidate) {
        let best = null, bestSize = -1;
        for (const f of files) {
          const fp = path.join(jobDir, f);
          const stat = fs.statSync(fp);
          if (stat.isFile() && stat.size > bestSize) { bestSize = stat.size; best = f; }
        }
        candidate = best;
      }
      if (!candidate) {
        progressMap.set(runId, { status: 'error', message: 'Output file not found' });
        cleanupJob(jobDir);
        return;
      }
      
      const filePath = path.join(jobDir, candidate);
      const ext = path.extname(candidate) || '';
      
      // Variable to store metadata response
      let metadataResp = null;
      
      // Siempre enriquecer metadatos para archivos MP3
      if (ext.toLowerCase() === '.mp3' && (parsedSong || videoTitle)) {
        try {
          progressMap.set(runId, { status: 'enriching', progress: 98 });
          console.log('[ENRICH] Searching Spotify for:', parsedSong || videoTitle, parsedArtist);
          
          // Auto-llamada al endpoint /metadata
          const metadataUrl = new URL('http://localhost:24725/metadata');
          metadataUrl.searchParams.set('title', parsedSong || videoTitle);
          if (parsedArtist) {
            metadataUrl.searchParams.set('artist', parsedArtist);
          }
          
          console.log('[ENRICH] Calling metadata API:', metadataUrl.toString());
          
          metadataResp = await new Promise((resolve, reject) => {
            http.get(metadataUrl.toString(), (res) => {
              let data = '';
              res.on('data', chunk => data += chunk);
              res.on('end', () => {
                if (res.statusCode === 200) {
                  try {
                    resolve(JSON.parse(data));
                  } catch (e) {
                    reject(new Error('Invalid JSON response'));
                  }
                } else {
                  resolve(null);
                }
              });
              res.on('error', reject);
            }).on('error', reject);
          });
          
          if (metadataResp) {
            console.log('[ENRICH] Found metadata:', metadataResp.title, 'by', metadataResp.artist);
            
            // Convertir la respuesta del API al formato que espera writeMetadataToFile
            // Necesitamos descargar el albumArt si está disponible
            let albumArtBuffer = null;
            if (metadataResp.albumArtUrl) {
              try {
                albumArtBuffer = await new Promise((resolve, reject) => {
                  https.get(metadataResp.albumArtUrl, (res) => {
                    const chunks = [];
                    res.on('data', chunk => chunks.push(chunk));
                    res.on('end', () => resolve(Buffer.concat(chunks)));
                    res.on('error', reject);
                  }).on('error', reject);
                });
              } catch (err) {
                console.warn('[ENRICH] Failed to download album art:', err);
              }
            }
            
            // VALIDAR que el metadata de Spotify coincida con lo buscado
            const searchTitle = parsedSong || videoTitle;
            const isValid = validateMetadata(
              searchTitle,
              parsedArtist,
              metadataResp.title,
              metadataResp.artist
            );
            
            if (!isValid) {
              console.warn('[ENRICH] ⚠️  Spotify metadata rejected - similarity too low');
              console.warn('[ENRICH] Searched:', searchTitle, 'by', parsedArtist);
              console.warn('[ENRICH] Got:', metadataResp.title, 'by', metadataResp.artist);
              console.log('[ENRICH] Using YouTube metadata instead');
              
              // Descargar thumbnail de YouTube
              let youtubeThumbnailBuffer = null;
              if (youtubeThumbnailUrl) {
                try {
                  console.log('[THUMBNAIL] Downloading YouTube thumbnail...');
                  youtubeThumbnailBuffer = await new Promise((resolve, reject) => {
                    https.get(youtubeThumbnailUrl, (res) => {
                      const chunks = [];
                      res.on('data', chunk => chunks.push(chunk));
                      res.on('end', () => resolve(Buffer.concat(chunks)));
                      res.on('error', reject);
                    }).on('error', reject);
                  });
                  console.log('[THUMBNAIL] Downloaded YouTube thumbnail:', youtubeThumbnailBuffer.length, 'bytes');
                } catch (err) {
                  console.warn('[THUMBNAIL] Failed to download YouTube thumbnail:', err);
                }
              }
              
              // Escribir metadatos de YouTube como fallback
              const youtubeMetadata = {
                title: parsedSong || videoTitle,
                artist: parsedArtist || 'Unknown',
                album: 'YouTube',
                year: new Date().getFullYear().toString(),
                trackNumber: null,
                albumArt: youtubeThumbnailBuffer,
                isrc: null,
                spotifyUrl: null
              };
              
              console.log('[ENRICH] Writing YouTube metadata:', youtubeMetadata.title, 'by', youtubeMetadata.artist);
              await writeMetadataToFile(filePath, youtubeMetadata);
              videoTitle = sanitizeFilename(`${youtubeMetadata.artist} - ${youtubeMetadata.title}`);
            } else {
              console.log('[ENRICH] ✓ Metadata validated successfully');
              
              const metadata = {
                title: metadataResp.title,
                artist: metadataResp.artist,
                album: metadataResp.album,
                year: metadataResp.year,
                trackNumber: metadataResp.trackNumber,
                albumArt: albumArtBuffer,
                isrc: metadataResp.isrc,
                spotifyUrl: metadataResp.spotifyUrl
              };
              
              // Trim silence to match Spotify duration (for better lyrics sync)
              if (metadataResp.duration) {
                await trimSilenceToMatchDuration(filePath, metadataResp.duration);
              }
              
              await writeMetadataToFile(filePath, metadata);
              videoTitle = sanitizeFilename(`${metadata.artist} - ${metadata.title}`);
            }
            // videoTitle ya se actualizó arriba si el metadata fue válido
          } else {
            console.log('[ENRICH] No Spotify metadata found, using YouTube metadata');
            
            // Descargar thumbnail de YouTube
            let youtubeThumbnailBuffer = null;
            if (youtubeThumbnailUrl) {
              try {
                console.log('[THUMBNAIL] Downloading YouTube thumbnail...');
                youtubeThumbnailBuffer = await new Promise((resolve, reject) => {
                  https.get(youtubeThumbnailUrl, (res) => {
                    const chunks = [];
                    res.on('data', chunk => chunks.push(chunk));
                    res.on('end', () => resolve(Buffer.concat(chunks)));
                    res.on('error', reject);
                  }).on('error', reject);
                });
                console.log('[THUMBNAIL] Downloaded YouTube thumbnail:', youtubeThumbnailBuffer.length, 'bytes');
              } catch (err) {
                console.warn('[THUMBNAIL] Failed to download YouTube thumbnail:', err);
              }
            }
            
            // Escribir metadatos de YouTube
            const youtubeMetadata = {
              title: parsedSong || videoTitle,
              artist: parsedArtist || 'Unknown',
              album: 'YouTube',
              year: new Date().getFullYear().toString(),
              trackNumber: null,
              albumArt: youtubeThumbnailBuffer,
              isrc: null,
              spotifyUrl: null
            };
            
            console.log('[ENRICH] Writing YouTube metadata:', youtubeMetadata.title, 'by', youtubeMetadata.artist);
            await writeMetadataToFile(filePath, youtubeMetadata);
            videoTitle = sanitizeFilename(`${youtubeMetadata.artist} - ${youtubeMetadata.title}`);
          }
        } catch (err) {
          console.error('[ENRICH] Error:', err);
          
          // Fallback: escribir metadatos de YouTube si hay error
          try {
            // Descargar thumbnail de YouTube
            let youtubeThumbnailBuffer = null;
            if (youtubeThumbnailUrl) {
              try {
                console.log('[THUMBNAIL] Downloading YouTube thumbnail...');
                youtubeThumbnailBuffer = await new Promise((resolve, reject) => {
                  https.get(youtubeThumbnailUrl, (res) => {
                    const chunks = [];
                    res.on('data', chunk => chunks.push(chunk));
                    res.on('end', () => resolve(Buffer.concat(chunks)));
                    res.on('error', reject);
                  }).on('error', reject);
                });
                console.log('[THUMBNAIL] Downloaded YouTube thumbnail:', youtubeThumbnailBuffer.length, 'bytes');
              } catch (thumbErr) {
                console.warn('[THUMBNAIL] Failed to download YouTube thumbnail:', thumbErr);
              }
            }
            
            const youtubeMetadata = {
              title: parsedSong || videoTitle,
              artist: parsedArtist || 'Unknown',
              album: 'YouTube',
              year: new Date().getFullYear().toString(),
              trackNumber: null,
              albumArt: youtubeThumbnailBuffer,
              isrc: null,
              spotifyUrl: null
            };
            
            console.log('[ENRICH] Error fallback - Writing YouTube metadata:', youtubeMetadata.title, 'by', youtubeMetadata.artist);
            await writeMetadataToFile(filePath, youtubeMetadata);
            videoTitle = sanitizeFilename(`${youtubeMetadata.artist} - ${youtubeMetadata.title}`);
          } catch (fallbackErr) {
            console.error('[ENRICH] Fallback metadata write failed:', fallbackErr);
          }
        }
      }
      
      // Upload to Google Drive and cache in database (only for MP3 files)
      if (ext.toLowerCase() === '.mp3' && parsedSong && parsedArtist) {
        try {
          progressMap.set(runId, { status: 'caching', progress: 99 });
          console.log('[CACHE] Uploading to Google Drive:', parsedSong, 'by', parsedArtist);
          
          const fileName = sanitizeFilename(`${parsedArtist} - ${parsedSong}`) + '.mp3';
          const driveResult = await googleDrive.uploadFile(filePath, fileName);
          
          // Save to database
          await cacheDB.addSong({
            title: parsedSong,
            artist: parsedArtist,
            album: metadataResp?.album || null,
            duration: metadataResp?.duration || null,
            thumbnailUrl: metadataResp?.albumArtUrl || null,
            googleDriveId: driveResult.fileId,
            googleDriveUrl: driveResult.downloadUrl,
            lyrics: null, // Can be added later
            metadata: metadataResp || null
          });
          
          console.log('[CACHE] ✓ Song cached successfully');
        } catch (err) {
          console.error('[CACHE] Error uploading to Drive:', err);
          // Continue anyway, don't fail the download
        }
      }
      
      
      const finalName = sanitizeFilename(videoTitle) + ext;
      progressMap.set(runId, { status: 'ready', progress: 100, filePath, filename: finalName, jobDir });
      console.log(`[JOB ${runId}] ready -> ${finalName}`);
    } catch (e) {
      progressMap.set(runId, { status: 'error', message: e?.message || String(e) });
      cleanupJob(jobDir);
    }
  });
});

// Idempotent download
app.get('/download-file/:jobId', (req, res) => {
  const jobId = req.params.jobId;
  const info = progressMap.get(jobId);
  if (!info) return res.status(404).json({ error: 'Job not found' });

  if (info.status === 'streaming') {
    return res.status(409).json({ error: 'Already streaming this job' });
  }
  if (info.status === 'complete') {
    return res.status(410).json({ error: 'Job already completed' });
  }

  if (info.status !== 'ready') {
    return res.status(400).json({ error: 'File not ready', status: info.status });
  }

  const { filePath, filename, jobDir } = info;
  if (!fs.existsSync(filePath)) {
    progressMap.set(jobId, { status: 'error', message: 'File missing' });
    return res.status(404).json({ error: 'File missing' });
  }

  progressMap.set(jobId, { ...info, status: 'streaming' });

  console.log(`[DOWNLOAD-FILE] Sending ${filename} for job ${jobId}`);
  res.download(filePath, filename, (err) => {
    if (err) {
      console.error(`[JOB ${jobId}] send error:`, err.message);
      progressMap.set(jobId, { status: 'error', message: 'Send failed' });
    } else {
      console.log(`[JOB ${jobId}] File sent successfully`);
      progressMap.set(jobId, { status: 'complete', progress: 100 });
    }
    setTimeout(() => {
      try { cleanupJob(jobDir); } catch (_) {}
      progressMap.delete(jobId);
    }, 3000);
  });
});

// Automatic cache cleanup - runs daily
async function performCacheCleanup() {
  try {
    console.log('[CACHE-CLEANUP] Starting automatic cleanup...');
    const oldSongs = await cacheDB.cleanupOldSongs(CACHE_EXPIRATION_DAYS);
    
    if (oldSongs.length > 0) {
      console.log(`[CACHE-CLEANUP] Found ${oldSongs.length} songs to remove`);
      const driveIds = oldSongs.map(s => s.google_drive_id);
      const deleteResults = await googleDrive.deleteFiles(driveIds);
      
      const successCount = deleteResults.filter(r => r.success).length;
      console.log(`[CACHE-CLEANUP] ✓ Cleaned up ${successCount}/${oldSongs.length} songs from Google Drive`);
    } else {
      console.log('[CACHE-CLEANUP] No old songs to clean up');
    }
  } catch (err) {
    console.error('[CACHE-CLEANUP] Error:', err);
  }
}

// Aggressive Temp File Cleanup
function performAggressiveCleanup() {
  try {
    console.log('[SYS-CLEANUP] Checking for orphaned temp files...');
    if (fs.existsSync(TEMP_DIR)) {
      const files = fs.readdirSync(TEMP_DIR);
      const now = Date.now();
      let deletedCount = 0;
      
      files.forEach(file => {
        const filePath = path.join(TEMP_DIR, file);
        try {
          const stats = fs.statSync(filePath);
          // Delete files older than 1 hour
          if (now - stats.mtimeMs > 60 * 60 * 1000) {
            fs.unlinkSync(filePath);
            deletedCount++;
          }
        } catch (e) {
          // Ignore busy/missing files
        }
      });
      
      if (deletedCount > 0) {
        console.log(`[SYS-CLEANUP] Removed ${deletedCount} orphaned temp files`);
      }
    }
  } catch (err) {
    console.error('[SYS-CLEANUP] Error:', err);
  }
}

// RAM & Cache Optimization
function performMemoryOptimization() {
  try {
    // 1. Enforce cache limit
    const MAX_CACHE_SIZE = 500;
    if (metadataCache.size > MAX_CACHE_SIZE) {
      console.log('[MEM-OPT] Pruning metadata cache...');
      let entriesToDelete = metadataCache.size - MAX_CACHE_SIZE;
      const sortedKeys = Array.from(metadataCache.keys()); 
      // This is simple FIFO if insertion order is preserved (Map usually does)
      // or we can sort by timestamp if strictly needed, but FIFO is fast enough
      for (let i = 0; i < entriesToDelete; i++) {
         metadataCache.delete(sortedKeys[i]);
      }
      console.log(`[MEM-OPT] Removed ${entriesToDelete} old cache entries`);
    }

    // 2. Force GC if available (requires --expose-gc flag usually, but good to have logic ready)
    if (global.gc) {
        const used = process.memoryUsage().heapUsed / 1024 / 1024;
        if (used > 500) { // If heap > 500MB
            console.log(`[MEM-OPT] High memory usage (${used.toFixed(2)}MB), forcing GC...`);
            global.gc();
        }
    }
  } catch (err) {
     console.error('[MEM-OPT] Error during optimization:', err);
  }
}

// Run cleanup schedules
// Daily deep clean
setInterval(performCacheCleanup, 24 * 60 * 60 * 1000);
// Hourly temp file cleanup
setInterval(performAggressiveCleanup, 60 * 60 * 1000);
// 10-Minute memory check
setInterval(performMemoryOptimization, 10 * 60 * 1000);

// Run on startup
setTimeout(() => {
    performCacheCleanup();
    performAggressiveCleanup();
}, 60 * 1000);

// Cache endpoints list to avoid reading file on every request
let cachedEndpoints = null;

function getCachedEndpoints() {
  if (cachedEndpoints) return cachedEndpoints;
  
  try {
    const fileContent = fs.readFileSync(__filename, 'utf8');
    const routeRegex = /app\.(get|post|put|delete|patch)\s*\(\s*['"`]([^'"`]+)['"`]/g;
    let match;
    const endpoints = [];
    
    while ((match = routeRegex.exec(fileContent)) !== null) {
      endpoints.push({ 
        method: match[1].toUpperCase(), 
        path: match[2],
        status: 'active'
      });
    }
    cachedEndpoints = endpoints;
    return endpoints;
  } catch (err) {
    console.error('Error parsing endpoints:', err);
    return [];
  }
}

// Endpoint to list all available endpoints and status
app.get('/endpoints', (req, res) => {
  try {
    res.json({
      status: 'online',
      uptime: process.uptime(),
      timestamp: new Date().toISOString(),
      services: {
        spotify: !!spotifyApi.getAccessToken() ? 'operational' : 'auth_pending',
        ytdlp: !!YT_DLP_BINARY ? 'operational' : 'unavailable',
        ffmpeg: !!FFMPEG_BINARY ? 'operational' : 'unavailable'
      },
      endpoint_count: getCachedEndpoints().length,
      endpoints: getCachedEndpoints()
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to list endpoints: ' + err.message });
  }
});


app.listen(PORT, () => {
  console.log(`Media server listening on port ${PORT}`);
  console.log(`Tools dir: ${TOOLS_DIR}`);
  
  console.log('\n[INFO] Available Endpoints:');
  try {
    const fileContent = fs.readFileSync(__filename, 'utf8');
    const routeRegex = /app\.(get|post|put|delete|patch)\s*\(\s*['"`]([^'"`]+)['"`]/g;
    let match;
    const foundRoutes = [];
    
    while ((match = routeRegex.exec(fileContent)) !== null) {
      foundRoutes.push({ method: match[1].toUpperCase(), path: match[2] });
    }
    
    if (foundRoutes.length > 0) {
      foundRoutes.forEach(route => {
        console.log(`  ${route.method.padEnd(7)} ${route.path}`);
      });
    } else {
       console.log('  No se encontraron rutas explícitas en index.js');
    }
  } catch (err) {
    console.log('  (Error al leer endpoints del archivo:', err.message, ')');
  }
  console.log('');
});
