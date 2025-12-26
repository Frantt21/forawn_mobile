// google_drive.js - Google Drive API integration for caching MP3 files
const { google } = require('googleapis');
const fs = require('fs');
const path = require('path');

class GoogleDriveService {
  constructor() {
    this.oauth2Client = null;
    this.drive = null;
    this.folderId = process.env.GOOGLE_DRIVE_FOLDER_ID;
    this.initialize();
  }

  initialize() {
    try {
      // Initialize OAuth2 client
      this.oauth2Client = new google.auth.OAuth2(
        process.env.GOOGLE_DRIVE_CLIENT_ID,
        process.env.GOOGLE_DRIVE_CLIENT_SECRET,
        process.env.GOOGLE_DRIVE_REDIRECT_URI
      );

      // Set refresh token
      if (process.env.GOOGLE_DRIVE_REFRESH_TOKEN) {
        this.oauth2Client.setCredentials({
          refresh_token: process.env.GOOGLE_DRIVE_REFRESH_TOKEN
        });
      }

      // Initialize Drive API
      this.drive = google.drive({ version: 'v3', auth: this.oauth2Client });
      
      console.log('[GDRIVE] Google Drive service initialized');
    } catch (err) {
      console.error('[GDRIVE] Initialization error:', err);
    }
  }

  // Upload MP3 file to Google Drive
  async uploadFile(filePath, fileName) {
    if (!this.drive) {
      throw new Error('Google Drive not initialized');
    }

    try {
      console.log(`[GDRIVE] Uploading ${fileName}...`);

      const fileMetadata = {
        name: fileName,
        parents: this.folderId ? [this.folderId] : []
      };

      const media = {
        mimeType: 'audio/mpeg',
        body: fs.createReadStream(filePath)
      };

      const response = await this.drive.files.create({
        requestBody: fileMetadata,
        media: media,
        fields: 'id, name, webContentLink, webViewLink'
      });

      const fileId = response.data.id;

      // Make file publicly accessible
      await this.drive.permissions.create({
        fileId: fileId,
        requestBody: {
          role: 'reader',
          type: 'anyone'
        }
      });

      // Get direct download link
      const downloadUrl = `https://drive.google.com/uc?export=download&id=${fileId}`;

      console.log(`[GDRIVE] ✓ Uploaded: ${fileName} (ID: ${fileId})`);

      return {
        fileId: fileId,
        downloadUrl: downloadUrl,
        webViewLink: response.data.webViewLink
      };
    } catch (err) {
      console.error('[GDRIVE] Upload error:', err);
      throw err;
    }
  }

  // Delete file from Google Drive
  async deleteFile(fileId) {
    if (!this.drive) {
      throw new Error('Google Drive not initialized');
    }

    try {
      await this.drive.files.delete({
        fileId: fileId
      });

      console.log(`[GDRIVE] ✓ Deleted file: ${fileId}`);
      return true;
    } catch (err) {
      console.error(`[GDRIVE] Delete error for ${fileId}:`, err);
      return false;
    }
  }

  // Delete multiple files
  async deleteFiles(fileIds) {
    const results = [];
    
    for (const fileId of fileIds) {
      const success = await this.deleteFile(fileId);
      results.push({ fileId, success });
    }

    return results;
  }

  // Check if file exists
  async fileExists(fileId) {
    if (!this.drive) {
      return false;
    }

    try {
      await this.drive.files.get({
        fileId: fileId,
        fields: 'id'
      });
      return true;
    } catch (err) {
      return false;
    }
  }

  // Get file metadata
  async getFileMetadata(fileId) {
    if (!this.drive) {
      throw new Error('Google Drive not initialized');
    }

    try {
      const response = await this.drive.files.get({
        fileId: fileId,
        fields: 'id, name, size, createdTime, modifiedTime'
      });

      return response.data;
    } catch (err) {
      console.error(`[GDRIVE] Error getting metadata for ${fileId}:`, err);
      throw err;
    }
  }

  // List files in folder
  async listFiles(maxResults = 100) {
    if (!this.drive) {
      throw new Error('Google Drive not initialized');
    }

    try {
      const query = this.folderId 
        ? `'${this.folderId}' in parents and trashed=false`
        : 'trashed=false';

      const response = await this.drive.files.list({
        q: query,
        pageSize: maxResults,
        fields: 'files(id, name, size, createdTime, modifiedTime)'
      });

      return response.data.files || [];
    } catch (err) {
      console.error('[GDRIVE] Error listing files:', err);
      throw err;
    }
  }

  // Get storage quota
  async getStorageQuota() {
    if (!this.drive) {
      throw new Error('Google Drive not initialized');
    }

    try {
      const response = await this.drive.about.get({
        fields: 'storageQuota'
      });

      const quota = response.data.storageQuota;
      
      return {
        limit: parseInt(quota.limit),
        usage: parseInt(quota.usage),
        usageInDrive: parseInt(quota.usageInDrive),
        available: parseInt(quota.limit) - parseInt(quota.usage),
        percentUsed: (parseInt(quota.usage) / parseInt(quota.limit)) * 100
      };
    } catch (err) {
      console.error('[GDRIVE] Error getting quota:', err);
      throw err;
    }
  }

  // Generate OAuth URL for initial setup
  getAuthUrl() {
    const scopes = ['https://www.googleapis.com/auth/drive.file'];
    
    return this.oauth2Client.generateAuthUrl({
      access_type: 'offline',
      scope: scopes,
      prompt: 'consent'
    });
  }

  // Exchange authorization code for tokens
  async getTokensFromCode(code) {
    try {
      const { tokens } = await this.oauth2Client.getToken(code);
      return tokens;
    } catch (err) {
      console.error('[GDRIVE] Error getting tokens:', err);
      throw err;
    }
  }
}

module.exports = GoogleDriveService;
