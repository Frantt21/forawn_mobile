class DownloadInfo {
  final String name;
  final String artists;
  final String imageUrl;
  final String downloadUrl;
  final int durationMs;

  DownloadInfo({
    required this.name,
    required this.artists,
    required this.imageUrl,
    required this.downloadUrl,
    required this.durationMs,
  });

  factory DownloadInfo.fromJson(Map<String, dynamic> json) {
    return DownloadInfo(
      name: json['name'] ?? '',
      artists: json['artists'] ?? '',
      imageUrl: json['image'] ?? '',
      downloadUrl: json['download_url'] ?? '',
      durationMs: json['duration_ms'] ?? 0,
    );
  }
}