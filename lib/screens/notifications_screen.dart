import 'package:flutter/material.dart';
import '../services/notification_history_service.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => NotificationsScreenState();
}

class NotificationsScreenState extends State<NotificationsScreen> {
  List<DownloadNotification> _notifications = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  // Getter público para saber si hay notificaciones
  bool get hasNotifications => _notifications.isNotEmpty;

  // Método público para limpiar desde el AppBar
  void clearAllFromAppBar() {
    _clearAll();
  }

  Future<void> _loadNotifications() async {
    setState(() => _isLoading = true);
    try {
      final notifications = await NotificationHistoryService.getHistory();
      if (mounted) {
        setState(() {
          _notifications = notifications;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[NotificationsScreen] Error loading notifications: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Limpiar notificaciones'),
        content: const Text(
          '¿Estás seguro de que quieres eliminar todas las notificaciones?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await NotificationHistoryService.clearHistory();
      await _loadNotifications();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notificaciones eliminadas')),
        );
      }
    }
  }

  Future<void> _deleteNotification(String id) async {
    await NotificationHistoryService.removeNotification(id);
    await _loadNotifications();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Notificación eliminada')));
    }
  }

  IconData _getIconForType(NotificationType type) {
    switch (type) {
      case NotificationType.success:
        return Icons.check_circle;
      case NotificationType.error:
        return Icons.error;
      case NotificationType.info:
        return Icons.info;
    }
  }

  Color _getColorForType(NotificationType type) {
    switch (type) {
      case NotificationType.success:
        return Colors.green;
      case NotificationType.error:
        return Colors.red;
      case NotificationType.info:
        return Colors.blue;
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) return 'Ahora';
    if (difference.inMinutes < 60) return 'Hace ${difference.inMinutes} min';
    if (difference.inHours < 24) return 'Hace ${difference.inHours}h';
    if (difference.inDays == 1) return 'Ayer';
    if (difference.inDays < 7) return 'Hace ${difference.inDays}d';

    return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(
        left: 16.0,
        right: 16.0,
        top: 16.0,
        bottom: 100.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Content
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_notifications.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(48.0),
                child: Column(
                  children: [
                    Icon(
                      Icons.notifications_off_outlined,
                      size: 64,
                      color: textColor.withOpacity(0.3),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No hay notificaciones',
                      style: TextStyle(
                        color: textColor.withOpacity(0.5),
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Las notificaciones de descargas aparecerán aquí',
                      style: TextStyle(
                        color: textColor.withOpacity(0.4),
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _notifications.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final notification = _notifications[index];
                final icon = _getIconForType(notification.type);
                final color = _getColorForType(notification.type);

                return Card(
                  color: const Color.fromARGB(255, 45, 45, 45),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: color.withOpacity(0.2),
                      child: Icon(icon, color: color, size: 20),
                    ),
                    title: Text(
                      notification.title,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(
                          notification.message,
                          style: TextStyle(
                            color: textColor.withOpacity(0.7),
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatTimestamp(notification.timestamp),
                          style: TextStyle(
                            color: textColor.withOpacity(0.5),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.close,
                        color: textColor.withOpacity(0.5),
                        size: 20,
                      ),
                      onPressed: () => _deleteNotification(notification.id),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
