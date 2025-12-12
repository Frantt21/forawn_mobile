/// Modelo para el historial de descargas
class DownloadHistoryItem {
  final String id;
  final String name;
  final String artists;
  final String? imageUrl;
  final String downloadUrl;
  final DateTime downloadedAt;
  final String source; // 'spotify' o 'youtube'
  final int? durationMs;

  DownloadHistoryItem({
    required this.id,
    required this.name,
    required this.artists,
    this.imageUrl,
    required this.downloadUrl,
    required this.downloadedAt,
    required this.source,
    this.durationMs,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'artists': artists,
      'imageUrl': imageUrl,
      'downloadUrl': downloadUrl,
      'downloadedAt': downloadedAt.toIso8601String(),
      'source': source,
      'durationMs': durationMs,
    };
  }

  factory DownloadHistoryItem.fromJson(Map<String, dynamic> json) {
    return DownloadHistoryItem(
      id: json['id'] as String,
      name: json['name'] as String,
      artists: json['artists'] as String,
      imageUrl: json['imageUrl'] as String?,
      downloadUrl: json['downloadUrl'] as String,
      downloadedAt: DateTime.parse(json['downloadedAt'] as String),
      source: json['source'] as String,
      durationMs: json['durationMs'] as int?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DownloadHistoryItem && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
