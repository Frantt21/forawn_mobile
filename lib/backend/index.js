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
async function searchSpotifyMetadata(title, artist) {
  const cacheKey = `${title.toLowerCase()}_${artist.toLowerCase()}`;
  
  // Verificar caché
  const cached = metadataCache.get(cacheKey);
  if (cached && (Date.now() - cached.timestamp < CACHE_DURATION)) {
    console.log('[SPOTIFY] Using cached metadata for:', title);
    return cached.data;
  }
  
  try {
    const query = artist ? `track:${title} artist:${artist}` : title;
    const result = await spotifyApi.searchTracks(query, { limit: 1 });
    
    if (result.body.tracks.items.length === 0) {
      console.log('[SPOTIFY] No results found for:', query);
      return null;
    }
    
    const track = result.body.tracks.items[0];
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
    // Handle rate limiting
    if (err.statusCode === 429) {
      const retryAfter = err.headers?.['retry-after'] || 1;
      console.warn(`[SPOTIFY] Rate limited, retry after ${retryAfter}s`);
      await new Promise(resolve => setTimeout(resolve, retryAfter * 1000));
      return searchSpotifyMetadata(title, artist); // Retry
    }
    console.error('[SPOTIFY] Search error:', err);
    return null;
  }
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
      const artworkPath = `${filePath}.jpg`;
      fs.writeFileSync(artworkPath, metadata.albumArt);

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
  
  // Remove common YouTube metadata
  song = song.replace(/\(Official.*?\)/gi, '')
             .replace(/\[Official.*?\]/gi, '')
             .replace(/\(Visualizer\)/gi, '')
             .replace(/\[Visualizer\]/gi, '')
             .replace(/\(Lyric.*?\)/gi, '')
             .replace(/\[Lyric.*?\]/gi, '')
             .replace(/\(Audio\)/gi, '')
             .replace(/\[Audio\]/gi, '')
             .trim();
  
  // Try to extract artist
  if (song.includes(' - ')) {
    const parts = song.split(' - ');
    if (parts.length === 2) {
      artist = parts[0].trim();
      song = parts[1].trim();
    }
  } else if (song.includes(': ')) {
    const parts = song.split(': ');
    if (parts.length === 2) {
      artist = parts[0].trim();
      song = parts[1].trim();
    }
  } else if (song.includes(' | ')) {
    const parts = song.split(' | ');
    if (parts.length === 2) {
      artist = parts[0].trim();
      song = parts[1].trim();
    }
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
  
  // Siempre intentar obtener el título de YouTube para el nombre del archivo
  try {
    const metaArgs = ['-J', '--no-playlist', ...cookiesArgs, videoUrl];
    const meta = spawnSync(YT_DLP_BINARY, metaArgs, { encoding: 'utf8', timeout: 20000 });
    if (meta.status === 0 && meta.stdout) {
      const json = JSON.parse(meta.stdout);
      const title = json.title || (Array.isArray(json.entries) && json.entries[0]?.title) || '';
      videoTitle = sanitizeFilename(title || 'download');
      
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
          
          const metadataResp = await new Promise((resolve, reject) => {
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
            
            await writeMetadataToFile(filePath, metadata);
            videoTitle = sanitizeFilename(`${metadata.artist} - ${metadata.title}`);
          } else {
            console.log('[ENRICH] No Spotify metadata found, using original title');
          }
        } catch (err) {
          console.error('[ENRICH] Error:', err);
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

app.listen(PORT, () => {
  console.log(`Media server listening on port ${PORT}`);
  console.log(`Tools dir: ${TOOLS_DIR}`);
});
