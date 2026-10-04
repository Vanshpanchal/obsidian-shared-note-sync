import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../theme/vb_theme.dart';
import 'files_screen.dart';

enum AttachSource { photos, camera, files, browse }

/// The camera needs a phone; desktops only get the file pickers.
bool get cameraAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// "What do you want to attach?" bottom sheet.
Future<AttachSource?> showAttachSheet(
  BuildContext context, {
  bool browse = true,
}) {
  return showModalBottomSheet<AttachSource>(
    context: context,
    useSafeArea: true,
    // Lets the sheet use the full height (landscape, keyboard) and scroll if it still doesn't fit.
    isScrollControlled: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      Widget option(
        AttachSource source,
        IconData icon,
        String title,
        String subtitle,
      ) => ListTile(
        minTileHeight: 56,
        contentPadding: const EdgeInsets.symmetric(horizontal: Vb.space6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: scheme.primary),
        ),
        title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        onTap: () => Navigator.pop(context, source),
      );

      return SingleChildScrollView(
        padding: const EdgeInsets.only(top: Vb.space2, bottom: Vb.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(bottom: Vb.space3),
              decoration: BoxDecoration(
                color: scheme.outline,
                borderRadius: BorderRadius.circular(Vb.radiusPill),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Vb.space6,
                0,
                Vb.space6,
                Vb.space2,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Attach',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            option(
              AttachSource.photos,
              LucideIcons.imagePlus,
              'Photo library',
              'Pick one or more pictures',
            ),
            if (cameraAvailable)
              option(
                AttachSource.camera,
                LucideIcons.camera,
                'Take photo',
                'Use the camera',
              ),
            option(
              AttachSource.files,
              LucideIcons.filePlus,
              'Choose files',
              'PDFs, documents, anything up to the size limit',
            ),
            if (browse)
              option(
                AttachSource.browse,
                LucideIcons.folderOpen,
                'Already uploaded',
                'Link a file that’s on the server',
              ),
          ],
        ),
      );
    },
  );
}

class PickedFile {
  const PickedFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class PickResult {
  const PickResult(this.files, this.rejected);
  final List<PickedFile> files;

  /// Messages for files that were skipped (too large, unreadable).
  final List<String> rejected;
}

/// Opens the system picker for [source] and reads the chosen files, skipping any over
/// [maxBytes] before they are read into memory.
Future<PickResult> pickFiles(
  AttachSource source, {
  required int maxBytes,
}) async {
  final files = <PickedFile>[];
  final rejected = <String>[];

  void tooBig(String name) =>
      rejected.add('$name is over the ${formatBytes(maxBytes)} limit');

  if (source == AttachSource.camera) {
    final shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
    );
    if (shot == null) return const PickResult([], []);
    final size = await shot.length();
    if (size > maxBytes) {
      tooBig('The photo');
    } else {
      final ext = extensionOf(shot.name).isEmpty
          ? 'jpg'
          : extensionOf(shot.name);
      files.add(
        PickedFile(
          AssetNames.stamped('Photo', ext, DateTime.now()),
          await shot.readAsBytes(),
        ),
      );
    }
    return PickResult(files, rejected);
  }

  final picked = await FilePicker.pickFiles(
    type: source == AttachSource.photos ? FileType.image : FileType.any,
  );
  for (final f in picked) {
    try {
      final size = await f.length();
      if (size != null && size > maxBytes) {
        tooBig(f.name);
        continue;
      }
      final bytes = await f.readAsBytes();
      if (bytes.length > maxBytes) {
        tooBig(f.name);
        continue;
      }
      files.add(PickedFile(f.name, bytes));
    } catch (_) {
      rejected.add('${f.name} couldn’t be read');
    }
  }
  return PickResult(files, rejected);
}

/// The whole "attach" gesture: choose a source, pick, upload. Returns the stored files
/// (in order) so the caller can insert their links. Failed uploads stay in the repository's
/// tray with a Retry button.
Future<List<AssetInfo>> attachFiles(
  BuildContext context,
  AssetsRepository assets,
  bool browse,
) async {
  if (!assets.configured) {
    _toast(context, 'Set up the endpoint and API key first (menu → Settings).');
    return const [];
  }
  final source = await showAttachSheet(context, browse: browse);
  if (source == null || !context.mounted) return const [];

  if (source == AttachSource.browse) {
    final chosen = await Navigator.of(context).push<AssetInfo>(
      MaterialPageRoute(
        builder: (_) => FilesScreen(assets: assets, pickMode: true),
      ),
    );
    return chosen == null ? const [] : [chosen];
  }

  // Know the server's size limit before reading big files into memory.
  if (!assets.loaded) await assets.refresh();

  PickResult result;
  try {
    result = await pickFiles(source, maxBytes: assets.maxBytes);
  } catch (e) {
    if (context.mounted) _toast(context, 'Couldn’t open the picker: $e');
    return const [];
  }
  if (context.mounted && result.rejected.isNotEmpty) {
    _toast(context, result.rejected.join('\n'));
  }

  final saved = <AssetInfo>[];
  for (final f in result.files) {
    final info = await assets.upload(suggestedName: f.name, bytes: f.bytes);
    if (info != null) saved.add(info);
  }
  return saved;
}

void _toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
