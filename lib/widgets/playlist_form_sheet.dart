import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/playlist_model.dart';
import '../models/song.dart';
import '../services/language_service.dart';
import '../services/playlist_service.dart';

class PlaylistFormSheet extends StatefulWidget {
  final Playlist? playlistToEdit;
  final Song? songToAdd;

  final Color? backgroundColor;
  final Color? accentColor;

  const PlaylistFormSheet({
    super.key,
    this.playlistToEdit,
    this.songToAdd,
    this.backgroundColor,
    this.accentColor,
  });

  static Future<void> show(
    BuildContext context, {
    Playlist? playlistToEdit,
    Song? songToAdd,
    Color? backgroundColor,
    Color? accentColor,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PlaylistFormSheet(
        playlistToEdit: playlistToEdit,
        songToAdd: songToAdd,
        backgroundColor: backgroundColor,
        accentColor: accentColor,
      ),
    );
  }

  @override
  State<PlaylistFormSheet> createState() => _PlaylistFormSheetState();
}

class _PlaylistFormSheetState extends State<PlaylistFormSheet> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  String? _selectedImagePath;
  bool _isLoading = false;

  bool get isEditing => widget.playlistToEdit != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.playlistToEdit?.name ?? '',
    );
    _descController = TextEditingController(
      text: widget.playlistToEdit?.description ?? '',
    );
    _selectedImagePath = widget.playlistToEdit?.imagePath;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() => _selectedImagePath = image.path);
    }
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (isEditing) {
        await PlaylistService().updatePlaylist(
          widget.playlistToEdit!.id,
          name: _nameController.text.trim(),
          description: _descController.text.trim(),
          imagePath: _selectedImagePath,
        );
      } else {
        final playlist = await PlaylistService().createPlaylist(
          _nameController.text.trim(),
          description: _descController.text.trim(),
          imagePath: _selectedImagePath,
        );
        if (widget.songToAdd != null) {
          await PlaylistService().addSongToPlaylist(
            playlist.id,
            widget.songToAdd!,
          );
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final animation = ModalRoute.of(context)?.animation;

    Widget child = DraggableScrollableSheet(
      initialChildSize: 0.7 + (bottomInset > 0 ? 0.2 : 0),
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) {
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: widget.backgroundColor ?? Colors.grey[900],
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottomInset),
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Header
                Text(
                  isEditing
                      ? LanguageService().getText('edit_playlist')
                      : LanguageService().getText('new_playlist'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Imagen selector (más pequeño y estético)
                Center(
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: Stack(
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                            image: _selectedImagePath != null
                                ? DecorationImage(
                                    image:
                                        File(_selectedImagePath!).existsSync()
                                        ? FileImage(File(_selectedImagePath!))
                                        : NetworkImage(_selectedImagePath!)
                                              as ImageProvider,
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _selectedImagePath == null
                              ? const Icon(
                                  Icons.add_photo_alternate_rounded,
                                  color: Colors.white54,
                                  size: 40,
                                )
                              : null,
                        ),
                        if (_selectedImagePath != null)
                          Positioned(
                            bottom: -4,
                            right: -4,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color:
                                    widget.accentColor ?? Colors.purpleAccent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Name Input
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: widget.accentColor ?? Colors.purpleAccent,
                    decoration: InputDecoration(
                      hintText: LanguageService().getText('playlist_name'),
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: InputBorder.none,
                      prefixIcon: Icon(
                        Icons.queue_music_rounded,
                        color: Colors.white.withOpacity(0.5),
                        size: 20,
                      ),
                    ),
                    onChanged: (text) => setState(() {}),
                  ),
                ),
                const SizedBox(height: 20),

                // Description Input
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextField(
                    controller: _descController,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: widget.accentColor ?? Colors.purpleAccent,
                    decoration: InputDecoration(
                      hintText: LanguageService().getText('playlist_desc'),
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          LanguageService().getText('cancel'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              widget.accentColor ?? Colors.purpleAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          disabledBackgroundColor:
                              (widget.accentColor ?? Colors.purpleAccent)
                                  .withOpacity(0.3),
                        ),
                        onPressed:
                            (_nameController.text.trim().isEmpty || _isLoading)
                            ? null
                            : _save,
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Text(
                                isEditing
                                    ? LanguageService().getText('save')
                                    : LanguageService().getText('create'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (animation != null) {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final curvedValue = Curves.easeOutCubic.transform(animation.value);
          return Transform.scale(
            scale: 0.95 + (0.05 * curvedValue),
            child: child,
          );
        },
        child: child,
      );
    }

    return child;
  }
}
