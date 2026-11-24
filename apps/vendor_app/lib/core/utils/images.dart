import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../widgets/common.dart';

const maxImageBytes =
    5 * 1024 * 1024; // matches the Storage bucket limit (5 MB)
const _types = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

class PickedImage {
  const PickedImage({
    required this.name,
    required this.bytes,
    required this.extension,
    required this.contentType,
  });
  final String name, extension, contentType;
  final Uint8List bytes;
}

/// Lets the vendor pick images and validates format + size on the device BEFORE uploading. Rejected files are reported, never silently dropped.
Future<List<PickedImage>> pickImages(
  BuildContext context, {
  required int max,
}) async {
  if (max <= 0) return const [];
  final files = await ImagePicker().pickMultiImage(
    limit: max < 2 ? 2 : max,
    imageQuality: 85,
    maxWidth: 2048,
  );
  final out = <PickedImage>[];
  final problems = <String>[];
  for (final f in files.take(max)) {
    final dot = f.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : f.name.substring(dot + 1).toLowerCase();
    final type = _types[ext];
    if (type == null) {
      problems.add('${f.name}: only JPG, PNG or WebP');
      continue;
    }
    final bytes = await f.readAsBytes();
    if (bytes.length > maxImageBytes) {
      problems.add('${f.name}: larger than 5 MB');
      continue;
    }
    out.add(
      PickedImage(
        name: f.name,
        bytes: bytes,
        extension: ext == 'jpeg' ? 'jpg' : ext,
        contentType: type,
      ),
    );
  }
  if (files.length > max) {
    problems.add('Only $max more image${max == 1 ? '' : 's'} allowed');
  }
  if (problems.isNotEmpty && context.mounted) {
    showSnack(context, problems.join('\n'), error: true);
  }
  return out;
}
