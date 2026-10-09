import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'ai_types.dart';

/// Loads an image file for upload: reads it, shrinks it when its long edge is
/// larger than [maxEdge], and returns it base64-encoded. Never throws; returns
/// null when the file cannot be read.
class ImagePrep {
  static const String _tinyPng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  static String mimeFor(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  static Future<AiImage?> load(String path, {int maxEdge = 1280}) async {
    try {
      if (path.startsWith('mock_')) {
        return const AiImage(mime: 'image/png', base64: _tinyPng);
      }
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      var out = bytes;
      var mime = mimeFor(path);

      final shrunk = await _downscale(bytes, maxEdge);
      // Only use the re-encoded copy when it is really smaller.
      if (shrunk != null && shrunk.length < bytes.length) {
        out = shrunk;
        mime = 'image/png';
      }
      return AiImage(mime: mime, base64: base64Encode(out));
    } catch (_) {
      return null;
    }
  }

  /// Returns PNG bytes scaled so the long edge is [maxEdge], or null when no
  /// scaling is needed or decoding fails.
  static Future<Uint8List?> _downscale(Uint8List bytes, int maxEdge) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width;
      final h = desc.height;
      if (w <= maxEdge && h <= maxEdge) return null;
      final scale = maxEdge / (w > h ? w : h);
      final tw = (w * scale).round().clamp(1, maxEdge).toInt();
      final th = (h * scale).round().clamp(1, maxEdge).toInt();
      codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      desc?.dispose();
      buffer?.dispose();
    }
  }
}
