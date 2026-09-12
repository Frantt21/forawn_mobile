import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/language_service.dart';

class VideoDownloaderScreen extends StatefulWidget {
  const VideoDownloaderScreen({super.key});

  @override
  State<VideoDownloaderScreen> createState() => _VideoDownloaderScreenState();
}

class _VideoDownloaderScreenState extends State<VideoDownloaderScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          LanguageService().getText('video_downloader'),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: Text(
          LanguageService().getText('video_downloader'),
          style: const TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}