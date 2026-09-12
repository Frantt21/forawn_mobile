import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/spotify_track.dart';
import '../services/global_download_manager.dart';
import '../services/language_service.dart';
import '../services/ytdlp_service.dart';
import '../widgets/app_search_field.dart';
import 'download_history_screen.dart';

class VideoDownloaderScreen extends StatefulWidget {
  const VideoDownloaderScreen({super.key});

  @override
  State<VideoDownloaderScreen> createState() => _VideoDownloaderScreenState();
}

class _VideoDownloaderScreenState extends State<VideoDownloaderScreen> {
  final TextEditingController _controller = TextEditingController();
  final GlobalDownloadManager _downloadManager = GlobalDownloadManager();

  // UI state (equivalente al video_downloader de desktop)
  bool _loadingMeta = false;
  String? _videoTitle;
  String? _videoId;
  Uint8List? _thumbnailBytes;
  String? _thumbnailUrl;

  /// Labels legibles por format_id para el dropdown del dialogo.
  final ValueNotifier<Map<String, String>> _formatLabelsNotifier =
      ValueNotifier({});
  String? _selectedFormatId;

  /// SAF treeUri guardado por el screen de musica (misma carpeta destino).
  String? _treeUri;

  @override
  void initState() {
    super.initState();
    _loadTreeUri();
  }

  @override
  void dispose() {
    _controller.dispose();
    _formatLabelsNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadTreeUri() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() => _treeUri = prefs.getString('saf_tree_uri'));
      }
    } catch (_) {}
  }

  bool _isValidUrl(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    try {
      final u = Uri.parse(t);
      return u.hasScheme && u.isAbsolute;
    } catch (_) {
      return false;
    }
  }

  /// Extrae el videoId de una URL de YouTube (watch, youtu.be, shorts, embed).
  static final RegExp _videoIdRe = RegExp(
    r'(?:[?&]v=|youtu\.be/|/shorts/|/embed/)([A-Za-z0-9_-]{11})',
  );

  /// Descarga los bytes de la miniatura probando URLs candidatas en orden:
  /// maxres -> sd -> hq -> mq -> la que reporte yt-dlp (mismo fallback del
  /// video_downloader de desktop).
  Future<Uint8List?> _fetchThumbnailBytes(List<String> urls) async {
    try {
      for (final raw in urls) {
        if (raw.isEmpty) continue;
        try {
          final resp = await http
              .get(Uri.parse(raw))
              .timeout(const Duration(seconds: 8));
          if (resp.statusCode == 200 && resp.bodyBytes.lengthInBytes > 1024) {
            return resp.bodyBytes;
          }
        } catch (_) {
          // Probar la siguiente URL candidata.
        }
      }
    } catch (_) {}
    return null;
  }

  /// Lista de URLs de miniatura candidatas para un video de YouTube, de
  /// mayor a menor resolucion.
  List<String> _thumbnailCandidates(String url, String? ytdlpThumb) {
    final candidates = <String>[];
    final m = _videoIdRe.firstMatch(url);
    final videoId = m?.group(1);
    if (videoId != null) {
      candidates.addAll([
        'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
        'https://i.ytimg.com/vi/$videoId/sddefault.jpg',
        'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
      ]);
    }
    if (ytdlpThumb != null && ytdlpThumb.isNotEmpty) {
      candidates.add(ytdlpThumb);
    }
    return candidates;
  }

  /// Convierte la lista de formatos cruda de yt-dlp en labels legibles
  /// ordenados de mayor a menor resolucion (misma logica que desktop).
  Map<String, String> _buildFormatLabels(List<dynamic> formats) {
    final res = <Map<String, dynamic>>[];
    for (final f in formats.whereType<Map<String, dynamic>>()) {
      res.add({
        'format_id': f['format_id'],
        'ext': f['ext'],
        'height': f['height'],
        'width': f['width'],
        'acodec': f['acodec'],
        'vcodec': f['vcodec'],
        'filesize': f['filesize'] ?? f['filesize_approx'],
      });
    }
    int heightOf(Map<String, dynamic> f) {
      final h = f['height'];
      if (h is int) return h;
      return int.tryParse('${h ?? 0}') ?? 0;
    }

    res.sort((a, b) => heightOf(b).compareTo(heightOf(a)));

    final labels = <String, String>{};
    for (final f in res) {
      final fid = f['format_id']?.toString() ?? '';
      if (fid.isEmpty) continue;
      if (labels.containsKey(fid)) continue;

      final height = heightOf(f);
      final ext = f['ext']?.toString() ?? '';
      final size = f['filesize'];
      String sizeStr = '';
      if (size is num && size > 0) {
        final mb = size / (1024 * 1024);
        sizeStr = ' - ${mb.toStringAsFixed(1)} MB';
      }
      final vcodec = f['vcodec']?.toString() ?? '';
      final acodec = f['acodec']?.toString() ?? '';
      final isAudioOnly = height == 0 && (vcodec == 'none' || vcodec.isEmpty);

      labels[fid] = isAudioOnly
          ? 'Audio $acodec$sizeStr'
          : height > 0
              ? '${height}p $ext$sizeStr'
              : 'Unknown $ext$sizeStr';
    }
    return labels;
  }

  // --- Acciones -------------------------------------------------------------

  Future<void> _onInspectUrl() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    if (!_isValidUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LanguageService().getText('invalid_url')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _loadingMeta = true;
      _videoTitle = null;
      _videoId = null;
      _thumbnailBytes = null;
      _thumbnailUrl = null;
      _formatLabelsNotifier.value = {};
      _selectedFormatId = null;
    });

    try {
      // Inicializar el motor embebido antes del primer uso.
      await YtDlpService().ensureInitialized();

      final meta = await YtDlpService().fetchVideoMetadata(url);
      if (meta == null) {
        if (!mounted) return;
        setState(() => _loadingMeta = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('meta_error')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final title = (meta['title'] ?? url).toString();
      final thumbUrl = meta['thumbnail'] as String?;
      final idMatch = _videoIdRe.firstMatch(url);
      _videoId = idMatch?.group(1) ?? meta['id']?.toString();

      // Miniatura con fallbacks (en background, actualiza al llegar).
      unawaited(
        _fetchThumbnailBytes(_thumbnailCandidates(url, thumbUrl)).then((bytes) {
          if (mounted && bytes != null) {
            setState(() => _thumbnailBytes = bytes);
          }
        }),
      );

      if (!mounted) return;
      setState(() {
        _videoTitle = title;
        _thumbnailUrl = thumbUrl;
        _loadingMeta = false;
      });

      await _showFormatsDialog(url, meta);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMeta = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// Dialogo de resolucion con el estilo de dialogos de la app. El dropdown
  /// reacciona al ValueNotifier de labels.
  Future<void> _showFormatsDialog(
    String url,
    Map<String, dynamic> meta,
  ) async {
    // Los metadatos ya estan: llenar labels inmediatamente.
    _formatLabelsNotifier.value = _buildFormatLabels(
      meta['formats'] as List<dynamic>? ?? [],
    );

    String? chosenFormat = _selectedFormatId;
    final sel = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setStateDialog) {
            return ValueListenableBuilder<Map<String, String>>(
              valueListenable: _formatLabelsNotifier,
              builder: (ctx3, labels, _) {
                if (labels.isNotEmpty &&
                    (chosenFormat == null ||
                        !labels.containsKey(chosenFormat))) {
                  chosenFormat = labels.keys.first;
                }
                return AlertDialog(
                  backgroundColor: const Color(0xFF1C1C1E),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: Text(
                    LanguageService().getText('choose_resolution'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_videoTitle != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 100,
                                height: 56,
                                color: Colors.grey[850],
                                child: _thumbnailBytes != null
                                    ? Image.memory(
                                        _thumbnailBytes!,
                                        fit: BoxFit.cover,
                                      )
                                    : const Icon(
                                        Icons.image,
                                        color: Colors.white24,
                                      ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _videoTitle!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 6),
                      if (labels.isEmpty)
                        Text(
                          LanguageService().getText('no_formats_yet'),
                          style: const TextStyle(color: Colors.white70),
                        )
                      else
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: chosenFormat,
                            // Estilo unificado de menus de la app.
                            dropdownColor: const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(15),
                            items: labels.entries.map((e) {
                              return DropdownMenuItem<String>(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            }).toList(),
                            onChanged: (v) =>
                                setStateDialog(() => chosenFormat = v),
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(LanguageService().getText('cancel')),
                    ),
                    ElevatedButton(
                      onPressed: (labels.isEmpty || chosenFormat == null)
                          ? null
                          : () => Navigator.of(ctx).pop(true),
                      child: Text(LanguageService().getText('download')),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    if (sel == true && chosenFormat != null && mounted) {
      await _addToQueue(url, chosenFormat!);
    }
  }

  /// Encola la descarga de video con el formato elegido (pasa por el
  /// GlobalDownloadManager: cola FIFO + notificaciones + historial).
  Future<void> _addToQueue(String url, String formatId) async {
    try {
      final track = SpotifyTrack(
        title: _videoTitle ?? url,
        artists: '',
        url: url,
        duration: '',
        popularity: '0',
      );

      await _downloadManager.addDownload(
        track: track,
        pinterestImageUrl: _thumbnailUrl,
        treeUri: _treeUri,
        videoFormatId: formatId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('added_to_queue')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(LanguageService().getText('video_downloader')),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const DownloadHistoryScreen(),
                ),
              );
            },
            tooltip: LanguageService().getText('download_history'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // URL input (widget compartido: estilo pill del video
              // downloader usado ahora en toda la app).
              AppSearchField(
                controller: _controller,
                hintText: LanguageService().getText('video_url_label'),
                isLoading: _loadingMeta,
                onSearch: _loadingMeta ? null : _onInspectUrl,
              ),
              const SizedBox(height: 12),

              // Preview: thumbnail + titulo + boton de resolucion
              if (!_loadingMeta &&
                  (_videoTitle != null || _thumbnailBytes != null))
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 160,
                        height: 90,
                        color: Colors.black26,
                        child: _thumbnailBytes != null
                            ? Image.memory(_thumbnailBytes!, fit: BoxFit.cover)
                            : const Center(
                                child: Icon(
                                  Icons.image,
                                  color: Colors.white24,
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _videoTitle ??
                                  LanguageService().getText('no_title'),
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.tune, size: 18),
                              label: Text(
                                LanguageService().getText('choose_resolution'),
                              ),
                              onPressed: _videoId != null
                                  ? () async {
                                      final url = _controller.text.trim();
                                      final meta = await YtDlpService()
                                          .fetchVideoMetadata(url);
                                      if (meta != null && mounted) {
                                        await _showFormatsDialog(url, meta);
                                      }
                                    }
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              if (_loadingMeta)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),

              // Empty state
              if (!_loadingMeta && _videoTitle == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library,
                          size: 48,
                          color: Colors.white.withOpacity(0.24),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          LanguageService().getText('enter_url_desc'),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
