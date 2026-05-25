import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class FileUtils {
  static IconData getFileIcon(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.webp':
      case '.heic':
        return Icons.photo_library_rounded; // More premium than basic image
      case '.mp4':
      case '.mkv':
      case '.avi':
      case '.mov':
      case '.webm':
        return Icons.smart_display_rounded; // Sleek TV/Play icon
      case '.mp3':
      case '.wav':
      case '.m4a':
      case '.flac':
      case '.ogg':
        return Icons.headphones_rounded; // Premium audio feel
      case '.pdf':
        return Icons.picture_as_pdf_rounded;
      case '.doc':
      case '.docx':
      case '.txt':
      case '.rtf':
      case '.md':
        return Icons.notes_rounded;
      case '.zip':
      case '.rar':
      case '.7z':
      case '.tar':
      case '.gz':
        return Icons.archive_rounded; // Professional archive icon
      case '.apk':
        return Icons.android_rounded;
      case '.exe':
      case '.msi':
        return Icons.terminal_rounded; // Dev/System feel
      default:
        if (ext.isEmpty) return Icons.folder_copy_rounded;
        return Icons.insert_drive_file_rounded;
    }
  }
}
