import 'package:flutter/material.dart';
import '../models/download_history_item.dart';
import '../services/download_history_service.dart';
import '../services/global_download_manager.dart';
import '../services/language_service.dart';

class DownloadHistoryScreen extends StatefulWidget {
  const DownloadHistoryScreen({super.key});

  @override
  State<DownloadHistoryScreen> createState() => _DownloadHistoryScreenState();
}

class _DownloadHistoryScreenState extends State<DownloadHistoryScreen> {
  final GlobalDownloadManager _downloadManager = GlobalDownloadManager();

  /// Historial persistido (solo completadas/fallidas en BD).
  List<DownloadHistoryItem> _history = [];
  bool _isLoading = true;

  /// Pill activa: 0 En curso, 1 En cola, 2 Completadas.
  int _tabIndex = 0;

  /// Ids ya persistidos: evita duplicar inserciones cuando la misma descarga
  /// sigue unos segundos visible en el stream tras completarse.
  final Set<String> _persistedIds = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final history = await DownloadHistoryService.getHistory();

    if (!mounted) return;
    setState(() {
      _history = history;
      // Precargar el set de ids para detectar duplicados del stream.
      for (final item in history) {
        _persistedIds.add(item.id);
      }
      _isLoading = false;
    });
  }

  /// Persiste inmediatamente una descarga que acaba de completar y la pasa
  /// al tab de Completadas sin esperar recargas.
  Future<void> _persistCompleted(ActiveDownload download) async {
    if (_persistedIds.contains(download.id)) return;
    _persistedIds.add(download.id);

    final item = DownloadHistoryItem(
      id: download.id,
      name: download.track.title,
      artists: download.track.artists,
      imageUrl: download.pinterestImageUrl,
      downloadUrl: download.track.url,
      downloadedAt: DateTime.now(),
      source: 'youtube',
      durationMs: null,
    );
    await DownloadHistoryService.addToHistory(item);

    if (!mounted) return;
    setState(() {
      _history.insert(0, item);
    });
  }

  /// Cuando el stream cambia: si alguna descarga pasó a completada, se
  /// persiste al momento y aparece en el tab de Completadas de inmediato.
  Future<void> _onDownloadsChanged(Map<String, ActiveDownload> downloads) async {
    for (final d in downloads.values) {
      if (d.phase == DownloadPhase.completed) {
        await _persistCompleted(d);
      }
    }
  }

  Future<void> _deleteItem(String id) async {
    await DownloadHistoryService.removeFromHistory(id);
    _persistedIds.remove(id);
    if (!mounted) return;
    setState(() {
      _history.removeWhere((item) => item.id == id);
    });

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
      _persistedIds.clear();
      if (!mounted) return;
      setState(() => _history = []);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(LanguageService().getText('history_cleared'))),
        );
      }
    }
  }

  /// Pill de tab con el estilo de _buildTabItem de local_music:
  /// AnimatedContainer r20, activa white 20% + texto blanco, inactiva
  /// white 5% + white60, bold 15, transición de 200ms.
  Widget _buildPill(String title, int index) {
    final isSelected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withOpacity(0.2) // Activa
              : Colors.white.withOpacity(0.05), // Inactiva
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            height: 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildPillTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPill(LanguageService().getText('tab_in_progress'), 0),
            const SizedBox(width: 8),
            _buildPill(LanguageService().getText('tab_queued'), 1),
            const SizedBox(width: 8),
            _buildPill(LanguageService().getText('tab_completed'), 2),
          ],
        ),
      ),
    );
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pills de tabs (estilo local_music) en lugar del TabBar.
          _buildPillTabs(),
          Expanded(
            child: StreamBuilder<Map<String, ActiveDownload>>(
          stream: _downloadManager.downloadsStream,
          initialData: _downloadManager.activeDownloads,
          builder: (context, snapshot) {
            final downloads = snapshot.data ?? const {};
            // Al actualizar el stream, persistir al instante las que ya
            // completaron: pasan al tab de Completadas en el mismo frame.
            _onDownloadsChanged(downloads);

            final inProgress = downloads.values
                .where((d) => d.phase == DownloadPhase.downloading)
                .toList();
            final queued = downloads.values
                .where((d) => d.phase == DownloadPhase.queued)
                .toList();

            final tabs = [
              _InProgressTab(
                items: inProgress,
                accentColor: accentColor,
                textColor: textColor,
                onCancel: (id) => _downloadManager.cancelDownload(id),
              ),
              _QueuedTab(
                items: queued,
                accentColor: accentColor,
                textColor: textColor,
                onCancel: (id) => _downloadManager.cancelDownload(id),
              ),
              _CompletedTab(
                items: _history,
                isLoading: _isLoading,
                accentColor: accentColor,
                textColor: textColor,
                onDelete: _deleteItem,
              ),
            ];
            // Selección por pills (sin swipe de TabBarView).
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(
                key: ValueKey<int>(_tabIndex),
                child: tabs[_tabIndex],
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

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

class _InProgressTab extends StatelessWidget {
  final List<ActiveDownload> items;
  final Color accentColor;
  final Color textColor;
  final void Function(String id) onCancel;

  const _InProgressTab({
    required this.items,
    required this.accentColor,
    required this.textColor,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _EmptyView(icon: Icons.download, messageKey: 'no_downloads_in_progress');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final d = items[index];
        final hasError = d.error != null;

        return _DownloadCard(
          accentColor: accentColor,
          textColor: textColor,
          imageUrl: d.pinterestImageUrl,
          title: d.track.title,
          subtitle: d.track.artists,
          trailing: hasError
              ? Text(
                  LanguageService().getText('error'),
                  style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                )
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => onCancel(d.id),
                  color: Colors.red.withOpacity(0.7),
                ),
          below: hasError
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    d.error!,
                    style: TextStyle(color: Colors.red.withOpacity(0.8), fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    Text(
                      '${(d.progress * 100).toInt()}%',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: d.progress > 0 ? d.progress : null,
                      backgroundColor: textColor.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _QueuedTab extends StatelessWidget {
  final List<ActiveDownload> items;
  final Color accentColor;
  final Color textColor;
  final void Function(String id) onCancel;

  const _QueuedTab({
    required this.items,
    required this.accentColor,
    required this.textColor,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _EmptyView(icon: Icons.low_priority, messageKey: 'no_downloads_queued');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final d = items[index];
        return _DownloadCard(
          accentColor: accentColor,
          textColor: textColor,
          imageUrl: d.pinterestImageUrl,
          title: d.track.title,
          subtitle: d.track.artists,
          badge: LanguageService().getText('badge_queued'),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => onCancel(d.id),
            color: Colors.red.withOpacity(0.7),
          ),
        );
      },
    );
  }
}

class _CompletedTab extends StatelessWidget {
  final List<DownloadHistoryItem> items;
  final bool isLoading;
  final Color accentColor;
  final Color textColor;
  final Future<void> Function(String id) onDelete;

  const _CompletedTab({
    required this.items,
    required this.isLoading,
    required this.accentColor,
    required this.textColor,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return const _EmptyView(icon: Icons.history, messageKey: 'no_downloads_in_history');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _DownloadCard(
          key: ValueKey(item.id),
          accentColor: accentColor,
          textColor: textColor,
          imageUrl: item.imageUrl,
          title: item.name,
          subtitle: item.artists,
          badge: _formatDateStatic(item.downloadedAt),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => onDelete(item.id),
            color: Colors.red.withOpacity(0.7),
          ),
        );
      },
    );
  }

  static String _formatDateStatic(DateTime date) {
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
}

// ---------------------------------------------------------------------------
// Widgets compartidos
// ---------------------------------------------------------------------------

class _DownloadCard extends StatelessWidget {
  final Color accentColor;
  final Color textColor;
  final String? imageUrl;
  final String title;
  final String subtitle;
  final String? badge;
  final Widget? trailing;
  final Widget? below;

  const _DownloadCard({
    super.key,
    required this.accentColor,
    required this.textColor,
    this.imageUrl,
    required this.title,
    required this.subtitle,
    this.badge,
    this.trailing,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: const Color.fromARGB(255, 45, 45, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 52,
                    height: 52,
                    color: accentColor.withOpacity(0.2),
                    child: (imageUrl != null && imageUrl!.isNotEmpty)
                        ? Image.network(
                            imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                Icon(Icons.music_note, color: accentColor),
                          )
                        : Icon(Icons.music_note, color: accentColor),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (below != null) below!,
            if (badge != null) ...[
              const SizedBox(height: 8),
              Text(
                badge!,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final IconData icon;
  final String messageKey;

  const _EmptyView({required this.icon, required this.messageKey});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text(
            LanguageService().getText(messageKey),
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
