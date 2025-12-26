// database.js - SQLite database manager for caching song metadata and download links
const Database = require('better-sqlite3');
const path = require('path');

class CacheDatabase {
  constructor(dbPath = path.join(__dirname, 'cache.db')) {
    this.db = new Database(dbPath);
    this.initDatabase();
    console.log('[DB] SQLite database initialized at:', dbPath);
  }

  initDatabase() {
    // Create songs cache table
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS songs_cache (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        song_id TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT,
        duration INTEGER,
        thumbnail_url TEXT,
        google_drive_id TEXT NOT NULL,
        google_drive_url TEXT NOT NULL,
        lyrics TEXT,
        metadata_json TEXT,
        created_at INTEGER NOT NULL,
        last_accessed INTEGER NOT NULL,
        access_count INTEGER DEFAULT 0
      )
    `);

    // Create indexes for faster lookups
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS idx_song_id ON songs_cache(song_id);
      CREATE INDEX IF NOT EXISTS idx_last_accessed ON songs_cache(last_accessed);
    `);

    console.log('[DB] Tables created/verified');
  }

  // Generate unique song ID from title and artist
  generateSongId(title, artist) {
    const normalized = `${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}`;
    return normalized.replace(/[^a-z0-9_]/g, '_');
  }

  // Add or update song in cache
  addSong(songData) {
    const {
      title,
      artist,
      album,
      duration,
      thumbnailUrl,
      googleDriveId,
      googleDriveUrl,
      lyrics,
      metadata
    } = songData;

    const songId = this.generateSongId(title, artist);
    const now = Date.now();

    const stmt = this.db.prepare(`
      INSERT INTO songs_cache (
        song_id, title, artist, album, duration, thumbnail_url,
        google_drive_id, google_drive_url, lyrics, metadata_json,
        created_at, last_accessed, access_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
      ON CONFLICT(song_id) DO UPDATE SET
        google_drive_id = excluded.google_drive_id,
        google_drive_url = excluded.google_drive_url,
        last_accessed = excluded.last_accessed,
        access_count = access_count + 1
    `);

    try {
      stmt.run(
        songId,
        title,
        artist,
        album || null,
        duration || null,
        thumbnailUrl || null,
        googleDriveId,
        googleDriveUrl,
        lyrics || null,
        metadata ? JSON.stringify(metadata) : null,
        now,
        now
      );
      console.log(`[DB] Added/Updated song: ${title} by ${artist}`);
      return songId;
    } catch (err) {
      console.error('[DB] Error adding song:', err);
      throw err;
    }
  }

  // Get song from cache
  getSong(title, artist) {
    const songId = this.generateSongId(title, artist);
    const stmt = this.db.prepare(`
      SELECT * FROM songs_cache WHERE song_id = ?
    `);

    try {
      const song = stmt.get(songId);
      
      if (song) {
        // Update last accessed time and count
        this.db.prepare(`
          UPDATE songs_cache 
          SET last_accessed = ?, access_count = access_count + 1
          WHERE song_id = ?
        `).run(Date.now(), songId);

        // Parse metadata JSON
        if (song.metadata_json) {
          try {
            song.metadata = JSON.parse(song.metadata_json);
          } catch (e) {
            console.warn('[DB] Error parsing metadata JSON:', e);
          }
        }

        console.log(`[DB] Cache HIT for: ${title} by ${artist}`);
        return song;
      }

      console.log(`[DB] Cache MISS for: ${title} by ${artist}`);
      return null;
    } catch (err) {
      console.error('[DB] Error getting song:', err);
      return null;
    }
  }

  // Clean up old songs (older than expiration days)
  cleanupOldSongs(expirationDays = 7) {
    const expirationTime = Date.now() - (expirationDays * 24 * 60 * 60 * 1000);
    
    const stmt = this.db.prepare(`
      SELECT song_id, title, artist, google_drive_id 
      FROM songs_cache 
      WHERE last_accessed < ?
    `);

    const oldSongs = stmt.all(expirationTime);

    if (oldSongs.length === 0) {
      console.log('[DB] No old songs to clean up');
      return [];
    }

    console.log(`[DB] Found ${oldSongs.length} songs to clean up`);

    // Delete from database
    const deleteStmt = this.db.prepare(`
      DELETE FROM songs_cache WHERE last_accessed < ?
    `);

    deleteStmt.run(expirationTime);

    console.log(`[DB] Cleaned up ${oldSongs.length} old songs`);
    return oldSongs; // Return list for Google Drive deletion
  }

  // Get cache statistics
  getStats() {
    const stats = this.db.prepare(`
      SELECT 
        COUNT(*) as total_songs,
        SUM(access_count) as total_accesses,
        AVG(access_count) as avg_accesses
      FROM songs_cache
    `).get();

    const recent = this.db.prepare(`
      SELECT COUNT(*) as recent_songs 
      FROM songs_cache 
      WHERE last_accessed > ?
    `).get(Date.now() - (24 * 60 * 60 * 1000));

    return {
      total_songs: stats.total_songs || 0,
      total_accesses: stats.total_accesses || 0,
      avg_accesses: stats.avg_accesses || 0,
      recent_songs: recent.recent_songs || 0
    };
  }

  // Close database connection
  close() {
    this.db.close();
    console.log('[DB] Database connection closed');
  }
}

module.exports = CacheDatabase;
