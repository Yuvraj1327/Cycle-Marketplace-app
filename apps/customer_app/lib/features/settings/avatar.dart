import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../app/theme.dart';
import '../../core/auth/auth_service.dart';
import '../../core/widgets/common.dart';

/// Profile pictures live in the PRIVATE `avatars` bucket under `<userId>/`; only the path is stored on the profile (`avatar_path`).
/// Binaries go straight to Supabase Storage with the user's own session and never through FastAPI.
abstract class AvatarStorage {
  /// Uploads and returns the storage path `<userId>/<random>.<ext>`.
  Future<String> upload({
    required String userId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  });

  /// A short-lived URL for showing a private picture; null when it cannot be produced.
  Future<String?> signedUrl(String path);

  /// Best effort: removes a replaced picture so old files do not pile up.
  Future<void> remove(String path);
}

class SupabaseAvatarStorage implements AvatarStorage {
  SupabaseAvatarStorage([sb.SupabaseClient? client])
    : _client = client ?? sb.Supabase.instance.client;
  final sb.SupabaseClient _client;
  static const bucket = 'avatars';

  @override
  Future<String> upload({
    required String userId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    // a new name per upload: the stored path changes, so cached copies of the old picture are never shown
    final name = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final path = '$userId/avatar-$name.$extension';
    try {
      await _client.storage
          .from(bucket)
          .uploadBinary(
            path,
            Uint8List.fromList(bytes),
            fileOptions: sb.FileOptions(contentType: contentType),
          );
    } on sb.StorageException catch (e) {
      throw AuthFailure(e.message);
    }
    return path;
  }

  @override
  Future<String?> signedUrl(String path) async {
    try {
      return await _client.storage.from(bucket).createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String path) async {
    try {
      await _client.storage.from(bucket).remove([path]);
    } catch (_) {}
  }
}

/// Used until `main()` wires the real one (and in tests that do not care about pictures): shows initials, refuses uploads.
class NoAvatarStorage implements AvatarStorage {
  const NoAvatarStorage();
  @override
  Future<String> upload({
    required String userId,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) => throw AuthFailure('Profile pictures are not available right now.');
  @override
  Future<String?> signedUrl(String path) async => null;
  @override
  Future<void> remove(String path) async {}
}

final avatarStorageProvider = Provider<AvatarStorage>(
  (ref) => const NoAvatarStorage(),
);

/// Signed URL for a stored picture, kept per path while something shows it.
final avatarUrlProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, path) => ref.watch(avatarStorageProvider).signedUrl(path),
);

class PickedAvatar {
  PickedAvatar(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
  static const maxBytes = 5 * 1024 * 1024; // the avatars bucket limit
  String get extension {
    final e = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
    return const {'jpg', 'jpeg', 'png', 'webp'}.contains(e)
        ? (e == 'jpeg' ? 'jpg' : e)
        : 'jpg';
  }

  String get contentType => switch (extension) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

/// Opens the gallery; null if cancelled. Overridden in tests.
final avatarPickerProvider = Provider<Future<PickedAvatar?> Function()>(
  (ref) => () async {
    final f = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    return f == null ? null : PickedAvatar(f.name, await f.readAsBytes());
  },
);

/// Round profile picture with an initial as the fallback. Shows nothing but the initial while the picture loads or if it cannot be loaded.
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.path,
    this.radius = 30,
  });
  final String name;
  final String? path;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = path;
    final url = (p == null || p.isEmpty)
        ? null
        : ref.watch(avatarUrlProvider(p)).asData?.value;
    final trimmed = name.trim();
    return CircleAvatar(
      radius: radius,
      backgroundColor: context.palette.primary,
      foregroundImage: url == null
          ? null
          : CachedNetworkImageProvider(url, cacheKey: p),
      child: Text(
        (trimmed.isEmpty ? '?' : trimmed[0]).toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * .8,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// The picture with a camera badge. Tapping it picks a photo, uploads it and hands the new path to [onUploaded], which saves it on the profile.
/// The previous file is removed only after the profile points at the new one.
class AvatarEditor extends ConsumerStatefulWidget {
  const AvatarEditor({
    super.key,
    required this.userId,
    required this.name,
    required this.path,
    required this.onUploaded,
    this.radius = 44,
  });
  final String userId, name;
  final String? path;
  final double radius;
  final Future<void> Function(String newPath) onUploaded;

  @override
  ConsumerState<AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends ConsumerState<AvatarEditor> {
  bool _busy = false;

  Future<void> _change() async {
    if (_busy) return;
    final storage = ref.read(avatarStorageProvider);
    final old = widget.path;
    try {
      final pick = await ref.read(avatarPickerProvider)();
      if (pick == null || !mounted) return;
      if (pick.bytes.length > PickedAvatar.maxBytes) {
        showSnack(context, 'Please choose a picture under 5 MB.', error: true);
        return;
      }
      setState(() => _busy = true);
      final path = await storage.upload(
        userId: widget.userId,
        bytes: pick.bytes,
        extension: pick.extension,
        contentType: pick.contentType,
      );
      try {
        await widget.onUploaded(path);
      } catch (_) {
        await storage.remove(
          path,
        ); // the profile was not updated: do not leave an orphan
        rethrow;
      }
      if (old != null && old.isNotEmpty && old != path) {
        await storage.remove(old);
      }
      if (mounted) showSnack(context, 'Profile picture updated');
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          e is AuthFailure ? e.message : errorText(e),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.radius;
    return Semantics(
      button: true,
      label: 'Change profile picture',
      child: InkResponse(
        onTap: _busy ? null : _change,
        radius: r + 8,
        child: Stack(
          alignment: Alignment.center,
          children: [
            UserAvatar(name: widget.name, path: widget.path, radius: r),
            if (_busy)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black45,
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: context.palette.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.palette.line),
                ),
                child: Icon(
                  Icons.photo_camera_outlined,
                  size: 16,
                  color: context.palette.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
