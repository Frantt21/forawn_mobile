import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class VersionCheckService {
  static const String _githubRepo = 'Frantt21/forawn_mobile';
  static const String _githubApiUrl =
      'https://api.github.com/repos/$_githubRepo/releases/latest';

  /// Obtener la última versión disponible en GitHub
  static Future<GitHubRelease?> getLatestRelease() async {
    try {
      final response = await http.get(Uri.parse(_githubApiUrl));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return GitHubRelease.fromJson(data);
      } else if (response.statusCode == 404) {
        // No hay releases todavía
        print('[VersionCheck] No releases found');
        return null;
      } else {
        print('[VersionCheck] Error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('[VersionCheck] Error fetching latest release: $e');
      return null;
    }
  }

  /// Comparar versiones y verificar si hay actualización disponible
  static Future<VersionCheckResult> checkForUpdate() async {
    try {
      // Obtener versión actual de la app
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Obtener última versión de GitHub
      final latestRelease = await getLatestRelease();

      if (latestRelease == null) {
        return VersionCheckResult(
          hasUpdate: false,
          currentVersion: currentVersion,
          latestVersion: null,
          downloadUrl: null,
          releaseNotes: null,
        );
      }

      // Comparar versiones
      final hasUpdate = _isNewerVersion(
        latestRelease.tagName.replaceAll('v', ''),
        currentVersion,
      );

      return VersionCheckResult(
        hasUpdate: hasUpdate,
        currentVersion: currentVersion,
        latestVersion: latestRelease.tagName,
        downloadUrl: latestRelease.downloadUrl,
        releaseNotes: latestRelease.body,
      );
    } catch (e) {
      print('[VersionCheck] Error checking for update: $e');
      return VersionCheckResult(
        hasUpdate: false,
        currentVersion: 'Unknown',
        latestVersion: null,
        downloadUrl: null,
        releaseNotes: null,
      );
    }
  }

  /// Comparar dos versiones (formato: x.y.z)
  static bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();

      for (int i = 0; i < 3; i++) {
        final latestPart = i < latestParts.length ? latestParts[i] : 0;
        final currentPart = i < currentParts.length ? currentParts[i] : 0;

        if (latestPart > currentPart) return true;
        if (latestPart < currentPart) return false;
      }

      return false; // Versiones iguales
    } catch (e) {
      print('[VersionCheck] Error comparing versions: $e');
      return false;
    }
  }
}

class GitHubRelease {
  final String tagName;
  final String name;
  final String body;
  final String? downloadUrl;
  final DateTime publishedAt;

  GitHubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    this.downloadUrl,
    required this.publishedAt,
  });

  factory GitHubRelease.fromJson(Map<String, dynamic> json) {
    // Buscar el asset APK si existe
    String? apkUrl;
    if (json['assets'] != null && json['assets'] is List) {
      for (var asset in json['assets']) {
        if (asset['name'].toString().endsWith('.apk')) {
          apkUrl = asset['browser_download_url'];
          break;
        }
      }
    }

    return GitHubRelease(
      tagName: json['tag_name'] ?? '',
      name: json['name'] ?? '',
      body: json['body'] ?? '',
      downloadUrl: apkUrl,
      publishedAt:
          DateTime.tryParse(json['published_at'] ?? '') ?? DateTime.now(),
    );
  }
}

class VersionCheckResult {
  final bool hasUpdate;
  final String currentVersion;
  final String? latestVersion;
  final String? downloadUrl;
  final String? releaseNotes;

  VersionCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    this.latestVersion,
    this.downloadUrl,
    this.releaseNotes,
  });
}
