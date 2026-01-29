// youtube_search.js - YouTube search service using youtube-search-api
const YoutubeSearchApi = require('youtube-search-api');

class YouTubeSearchService {
  constructor() {
    this.searchOptions = {
      limit: 40,
      safeSearch: false
    };
  }

  // Search YouTube videos
  async search(query, limit = 40) {
    try {
      console.log(`[YOUTUBE] Searching for: ${query}`);

      // youtube-search-api.GetListByKeyword is much simpler and less error-prone
      const response = await YoutubeSearchApi.GetListByKeyword(query, false, limit, [
        { type: 'video' }
      ]);

      if (!response || !response.items || response.items.length === 0) {
        console.log('[YOUTUBE] No results found');
        return [];
      }

      const videos = response.items
        .filter(item => item.type === 'video' && item.id)
        .map(video => {
          // Parse duration from "MM:SS" or "HH:MM:SS" format
          const durationInSeconds = this.parseDuration(video.length?.simpleText || '0:00');
          
          // Parse title to extract clean artist and song
          const rawTitle = video.title || '';
          const rawAuthor = video.channelTitle || 'Unknown';
          const fullTitle = rawAuthor !== 'Unknown' ? `${rawAuthor} - ${rawTitle}` : rawTitle;
          const parsed = this.parseTitle(fullTitle);
          
          return {
            id: video.id,
            title: rawTitle,
            url: `https://www.youtube.com/watch?v=${video.id}`,
            duration: durationInSeconds,
            durationText: video.length?.simpleText || '0:00',
            thumbnail: video.thumbnail?.thumbnails?.[0]?.url || '',
            author: rawAuthor,
            authorUrl: `https://www.youtube.com/channel/${video.channelId || ''}`,
            views: parseInt(video.viewCount?.replace(/[^0-9]/g, '') || '0', 10),
            uploadedAt: video.publishedTimeText || '',
            description: video.description || '',
            // Add parsed values
            parsedSong: parsed.song || rawTitle,
            parsedArtist: parsed.artist || rawAuthor
          };
        });

      // Ordenar por vistas (más populares primero)
      videos.sort((a, b) => (b.views || 0) - (a.views || 0));

      console.log(`[YOUTUBE] Found ${videos.length} results (sorted by popularity)`);
      return videos;
    } catch (err) {
      console.error('[YOUTUBE] Search error:', err);
      throw err;
    }
  }

  // Parse duration string (e.g., "3:45" -> 225 seconds)
  parseDuration(durationStr) {
    if (!durationStr) return 0;

    const parts = durationStr.split(':').map(p => parseInt(p, 10));
    
    if (parts.length === 2) {
      // MM:SS
      return parts[0] * 60 + parts[1];
    } else if (parts.length === 3) {
      // HH:MM:SS
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    }

    return 0;
  }

  // Format duration in seconds to MM:SS or HH:MM:SS
  formatDuration(seconds) {
    if (!seconds) return '0:00';

    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;

    if (hours > 0) {
      return `${hours}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
    } else {
      return `${minutes}:${secs.toString().padStart(2, '0')}`;
    }
  }

  // Extract artist and song from YouTube title
  parseTitle(title) {
    let artist = '';
    let song = title;
    
    // 1. Limpieza inicial agresiva
    song = song.replace(/[(\[]\s*(?:official|video|audio|lyrics?|letra|visualizer|hd|4k|8k|3d|live|vivo|studio|sesión|session|prod\.|produced)\s*(?:oficial|lyric|video|audio|by)?.*?[)\]]/gi, '')
               .replace(/[(\[]\s*360°?\s*visualizer\s*[)\]]/gi, '')
               .replace(/\s*-\s*Topic\s*$/i, '')
               .trim();
    
    let foundSep = false;
    
    // 2. Separación Jerárquica
    const separators = [' - ', ' : ', ' | ', ' /// ', ' // '];
    
    for (const sep of separators) {
      if (song.includes(sep)) {
        const parts = song.split(sep);
        if (parts.length >= 2) {
          artist = parts[0].trim();
          song = parts.slice(1).join(sep).trim();
          foundSep = true;
          break;
        }
      }
    }
    
    // Fallback "by"
    if (!foundSep && song.toLowerCase().includes(' by ')) {
      const parts = song.split(/\s+by\s+/i);
      if (parts.length >= 2) {
        song = parts[0].trim();
        artist = parts[1].trim();
        foundSep = true;
      }
    }
    
    // 3. Limpieza Secundaria del Título
    if (song) {
      if (song.includes('|')) song = song.split('|')[0].trim();
      if (song.includes('//')) song = song.split('//')[0].trim();
      if (song.includes('///')) song = song.split('///')[0].trim();
      
      // Clean feats
      song = song.replace(/\s*[(]?\s*(?:ft\.?|feat\.?|featuring|with|con)\s+.*?[)]?$/i, '');
      
      // Clean remix/version info
      song = song.replace(/[(\[]\s*(?:remix|mix|edit|version|ver|remaster|remastered).*?[)\]]/gi, '').trim();
    }
    
    // 4. Limpieza del Artista
    if (artist) {
      artist = artist.split(/\s*[(]?\s*(?:ft\.?|feat\.?|featuring|with|con|x|&)\s+/i)[0].trim();
    }
    
    return { artist, song };
  }

  // Search and parse results
  async searchAndParse(query, limit = 40) {
    const results = await this.search(query, limit);
    
    return results.map(video => {
      const parsed = this.parseTitle(video.title);
      
      return {
        ...video,
        parsedArtist: parsed.artist,
        parsedSong: parsed.song
      };
    });
  }
}

module.exports = YouTubeSearchService;
