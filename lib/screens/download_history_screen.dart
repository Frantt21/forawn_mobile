import 'package:flutter/material.dart';
import '../models/download_history_item.dart';
import '../services/download_history_service.dart';
import '../services/global_download_manager.dart';
import '../services/language_service.dart';
import '../utils/safe_http_mixin.dart';

class DownloadHistoryScreen extends StatefulWidget {
  const DownloadHistoryScreen({super.key});

  @override
  State<DownloadHistoryScreen> createState() => _DownloadHistoryScreenState();
}

class _DownloadHistoryScreenState extends State<DownloadHistoryScreen>
    with SafeHttpMixin {
  final GlobalDownloadManager _downloadManager = GlobalDownloadManager();
  List<DownloadHistoryItem> _history = [];
  List<DownloadHistoryItem> _filteredHistory = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    safeSetState(() => _isLoading = true);

    final history = await DownloadHistoryService.getHistory();

    safeSetState(() {
      _history = history;
      _filteredHistory = history;
      _isLoading = false;
    });
  }

  void _filterHistory(String query) {
    if (query.isEmpty) {
      safeSetState(() => _filteredHistory = _history);
      return;
    }

    final lowerQuery = query.toLowerCase();
    safeSetState(() {
      _filteredHistory = _history.where((item) {
        return item.name.toLowerCase().contains(lowerQuery) ||
            item.artists.toLowerCase().contains(lowerQuery);
      }).toList();
    });
  }

  Future<void> _deleteItem(String id) async {
    await DownloadHistoryService.removeFromHistory(id);
    await _loadHistory();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LanguageService().getText('deleted_from_history')),
        ),
      );
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(LanguageService().getText('clear_history')),
        content: Text(LanguageService().getText('clear_history_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(LanguageService().getText('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              LanguageService().getText('delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DownloadHistoryService.clearHistory();
      await _loadHistory();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(LanguageService().getText('history_cleared'))),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    final lang = LanguageService();

    if (difference.inDays == 0) {
      return '${lang.getText('today')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return lang.getText('yesterday');
    } else if (difference.inDays < 7) {
      return lang.getText('days_ago', {'days': '${difference.inDays}'});
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatDuration(int? ms) {
    if (ms == null) return '';
    final seconds = ms ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final textColor = theme.colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(
        title: Text(LanguageService().getText('download_history')),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clearAll,
              tooltip: LanguageService().getText('clear_all'),
            ),
        ],
      ),
      body: Column(
        children: [
          // Barra de búsqueda
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              color: const Color(0xFF0F0F10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LanguageService().getText('search_in_history'),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _searchController,
                      onChanged: _filterHistory,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      cursorColor: Colors.purpleAccent,
                      decoration: InputDecoration(
                        hintText: LanguageService().getText('song_or_artist'),
                        hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                        ),
                        border: InputBorder.none,
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 20),
                                onPressed: () {
                                  _searchController.clear();
                                  _filterHistory('');
                                },
                                color: Colors.white.withOpacity(0.5),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Descargas activas
          StreamBuilder<Map<String, dynamic>>(
            stream: _downloadManager.downloadsStream,
            initialData: _downloadManager.activeDownloads,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const SizedBox.shrink();
              }

              final activeDownloads = snapshot.data!.values.toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      '${LanguageService().getText('active_downloads')} (${activeDownloads.length})',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...activeDownloads.map((download) {
                    final track = download.track;
                    final progress = download.progress;
                    final isCompleted = download.isCompleted;
                    final hasError = download.error != null;

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      color: const Color.fromARGB(255, 45, 45, 45),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: accentColor.withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 56,
                            height: 56,
                            color: accentColor.withOpacity(0.2),
                            child: download.pinterestImageUrl != null
                                ? Image.network(
                                    download.pinterestImageUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                      Icons.music_note,
                                      color: accentColor,
                                    ),
                                  )
                                : Icon(Icons.music_note, color: accentColor),
                          ),
                        ),
                        title: Text(
                          track.title,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.artists,
                              style: TextStyle(
                                color: textColor.withOpacity(0.6),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (!isCompleted && !hasError)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${(progress * 100).toInt()}%',
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: textColor.withOpacity(0.1),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      accentColor,
                                    ),
                                  ),
                                ],
                              ),
                            if (isCompleted)
                              Text(
                                LanguageService().getText('completed'),
                                style: TextStyle(
                                  color: Colors.green,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            if (hasError)
                              Text(
                                'Error: ${download.error}',
                                style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                        trailing: !isCompleted && !hasError
                            ? IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _downloadManager.cancelDownload(download.id);
                                },
                                color: Colors.red.withOpacity(0.7),
                              )
                            : null,
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Divider(color: textColor.withOpacity(0.1)),
                  ),
                ],
              );
            },
          ),

          // Título de historial completado
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              LanguageService().getText('completed'),
              style: TextStyle(
                color: textColor,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Lista de historial completado
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredHistory.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.history,
                          size: 64,
                          color: Colors.white.withOpacity(0.2),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchController.text.isEmpty
                              ? LanguageService().getText(
                                  'no_downloads_in_history',
                                )
                              : LanguageService().getText('no_results_found'),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredHistory.length,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemBuilder: (context, index) {
                      final item = _filteredHistory[index];
                      return Card(
                        color: const Color.fromARGB(255, 45, 45, 45),
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          // side: BorderSide(
                          //   color: Colors.white.withOpacity(0.1),
                          //   width: 1,
                          // ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: item.imageUrl != null
                                ? Image.network(
                                    item.imageUrl!,
                                    width: 56,
                                    height: 56,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 56,
                                      height: 56,
                                      color: Colors.grey[800],
                                      child: const Icon(Icons.music_note),
                                    ),
                                  )
                                : Container(
                                    width: 56,
                                    height: 56,
                                    color: Colors.grey[800],
                                    child: const Icon(Icons.music_note),
                                  ),
                          ),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.artists,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    item.source == 'spotify'
                                        ? Icons.music_note
                                        : Icons.play_circle_outline,
                                    size: 14,
                                    color: Colors.white.withOpacity(0.4),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _formatDate(item.downloadedAt),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white.withOpacity(0.4),
                                    ),
                                  ),
                                  if (item.durationMs != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatDuration(item.durationMs),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white.withOpacity(0.4),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteItem(item.id),
                            color: Colors.red.withOpacity(0.7),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
