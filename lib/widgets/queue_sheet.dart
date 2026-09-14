// lib/widgets/queue_sheet.dart
//
// Cola de reproducción (lógica de Scrup QueueSheet/QueuePanel): bottom sheet
// con asa arrastrable, lista REORDENABLE (drag grip), pista actual resaltada
// con acento y swipe/tap para eliminar. Se abre desde el botón de cola del
// reproductor (junto a lyrics/shuffle/repeat).
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';

/// Abre la cola como bottom sheet (patrón QueueSheet de Scrup).
Future<void> showQueueSheet(BuildContext context, {int? dominantColor}) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => QueueSheet(dominantColor: dominantColor),
  );
}

class QueueSheet extends StatefulWidget {
  final int? dominantColor;

  const QueueSheet({super.key, this.dominantColor});

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  final AudioPlayerService _player = AudioPlayerService();

  Color get _accent => widget.dominantColor != null
      ? Color(widget.dominantColor!)
      : Colors.purpleAccent;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      decoration: BoxDecoration(
        color: Color.lerp(
              const Color(0xFF1C1C1E),
              widget.dominantColor != null
                  ? Color(widget.dominantColor!)
                  : Colors.purpleAccent,
              0.15,
            ) ??
            const Color(0xFF1C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Asa de arrastre.
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Cabecera: título + recuento.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.queue_music_rounded, size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      LanguageService().getText('queue'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  StreamBuilder<Object>(
                    stream: _player.playlistStream,
                    builder: (context, snap) {
                      final n = _player.queueSongs.length;
                      return Text(
                        '$n',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Flexible(
              child: StreamBuilder<Object>(
                stream: _player.playlistStream,
                builder: (context, _) {
                  final songs = _player.queueSongs;
                  final currentIdx = _player.queueIndex;
                  if (songs.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.queue_music_rounded,
                            size: 40,
                            color: _accent.withOpacity(0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            LanguageService().getText('queue_empty'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Material(
                    // Requerido: ReorderableListView/InkWell lo necesitan como
                    // ancestro ("No Material widget found" al arrastrar).
                    type: MaterialType.transparency,
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) =>
                          AnimatedBuilder(
                            animation: animation,
                            builder: (_, child) => Transform.scale(
                              scale: 1 + animation.value * 0.02,
                              child: child,
                            ),
                            // Material requerido: el proxy del arrastre se
                            // renderiza en el Overlay raíz, fuera del Material
                            // de la lista ("No Material widget found").
                            child: Material(
                              type: MaterialType.transparency,
                              child: child,
                            ),
                          ),
                      itemCount: songs.length,
                      onReorder: (oldIndex, newIndex) {
                        setState(() {
                          _player.reorderQueue(oldIndex, newIndex);
                        });
                      },
                      itemBuilder: (context, i) {
                        final song = songs[i];
                        final isCurrent = i == currentIdx;
                        return Dismissible(
                          key: ValueKey('dismiss_${song.id}_$i'),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) {
                            _player.removeFromQueue(i);
                            setState(() {});
                          },
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                          ),
                          child: _QueueTrackRow(
                            key: ValueKey('${song.id}_$i'),
                            index: i,
                            song: song,
                            isCurrent: isCurrent,
                            accent: _accent,
                            onTap: () => _player.playQueueAt(i),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fila reordenable de la cola: tap para reproducir, grip para arrastrar
/// (mismo patrón que Scrup _QueueTrackRow).
class _QueueTrackRow extends StatelessWidget {
  final int index;
  final Song song;
  final bool isCurrent;
  final Color accent;
  final VoidCallback onTap;

  const _QueueTrackRow({
    super.key,
    required this.index,
    required this.song,
    required this.isCurrent,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isCurrent
                      ? Colors.white.withOpacity(0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    // Artwork pequeño o número. artworkPath es una RUTA DE
                    // ARCHIVO en caché (no un asset): usar Image.file con
                    // errorBuilder por si el archivo temporal fue eliminado.
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      clipBehavior: Clip.antiAlias,
                      child: song.artworkPath != null
                          ? Image.file(
                              File(song.artworkPath!),
                              fit: BoxFit.cover,
                              width: 40,
                              height: 40,
                              errorBuilder: (_, __, ___) => isCurrent
                                  ? Icon(Icons.equalizer, color: accent, size: 16)
                                  : Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.4),
                                        fontSize: 12,
                                      ),
                                    ),
                            )
                          : isCurrent
                              ? Icon(Icons.equalizer, color: accent, size: 16)
                              : Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 12,
                                  ),
                                ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent ? accent : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.45),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.drag_indicator_rounded,
                size: 20,
                color: Colors.white.withOpacity(0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
