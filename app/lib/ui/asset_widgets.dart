import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../markdown/find_in_note.dart';
import '../theme/vb_theme.dart';

IconData iconForKind(AssetKind kind) => switch (kind) {
  AssetKind.image => LucideIcons.image,
  AssetKind.pdf => LucideIcons.fileText,
  AssetKind.audio => LucideIcons.music,
  AssetKind.video => LucideIcons.film,
  AssetKind.text => LucideIcons.fileText,
  AssetKind.archive => LucideIcons.fileArchive,
  AssetKind.other => LucideIcons.file,
};

/// Square thumbnail: the picture itself for images, a kind icon for everything else.
class AssetThumb extends StatelessWidget {
  const AssetThumb({
    super.key,
    required this.info,
    required this.repo,
    this.size = 48,
  });

  final AssetInfo info;
  final AssetsRepository repo;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Center(
      child: Icon(
        iconForKind(info.kind),
        size: size * 0.45,
        color: scheme.onSurfaceVariant,
      ),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Vb.radiusSm + 2),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: info.isImage
          ? Image(
              image: repo.imageFor(info, cacheWidth: (size * 3).round()),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Icon while the picture loads, and if it can't be shown.
              frameBuilder: (context, child, frame, sync) =>
                  frame == null && !sync ? fallback : child,
              errorBuilder: (_, _, _) => fallback,
            )
          : fallback,
    );
  }
}

/// `![[photo.png]]` in the preview: the image, full width up to the reading width,
/// with a skeleton while it loads and a retry card if it can't.
class AssetImageEmbed extends StatefulWidget {
  const AssetImageEmbed({
    super.key,
    required this.info,
    required this.repo,
    this.width,
    this.onTap,
  });

  final AssetInfo info;
  final AssetsRepository repo;

  /// From `![[photo.png|300]]`; null fills the available width.
  final double? width;
  final VoidCallback? onTap;

  @override
  State<AssetImageEmbed> createState() => _AssetImageEmbedState();
}

class _AssetImageEmbedState extends State<AssetImageEmbed> {
  int _attempt = 0;

  Future<void> _retry() async {
    await widget.repo.evictImage(widget.info);
    if (mounted) setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final maxWidth = (MediaQuery.sizeOf(context).width - 2 * Vb.space4).clamp(
      120.0,
      Vb.reading,
    );
    final width = widget.width == null
        ? maxWidth
        : widget.width!.clamp(40.0, maxWidth);

    Widget frame(Widget child) => Container(
      width: width,
      margin: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Vb.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );

    Widget message(
      IconData icon,
      String text, {
      bool retry = false,
    }) => Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(Vb.space4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Vb.space3),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
          if (retry) TextButton(onPressed: _retry, child: const Text('Retry')),
        ],
      ),
    );

    return Semantics(
      image: true,
      label: widget.info.name,
      child: frame(
        InkWell(
          onTap: widget.onTap,
          child: Image(
            key: ValueKey('${widget.info.cacheKey}#$_attempt'),
            image: widget.repo.imageFor(
              widget.info,
              cacheWidth: (width * 3).round(),
            ),
            width: width,
            fit: BoxFit.fitWidth,
            gaplessPlayback: true,
            // Until the first frame decodes the image has no height; hold the space so the
            // note doesn't jump when the picture appears.
            frameBuilder: (context, child, frame, sync) =>
                frame == null && !sync
                ? Container(
                    width: width,
                    height: width * 0.6,
                    color: vb.skeleton,
                  )
                : child,
            errorBuilder: (context, error, _) => message(
              LucideIcons.imageOff,
              'Couldn’t load ${widget.info.name}',
              retry: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// `[[Lease.pdf]]` / `![[Lease.pdf]]` for a file that isn't a picture.
class AssetFileChip extends StatelessWidget {
  const AssetFileChip({super.key, required this.info, this.onTap, this.finder});

  final NoteFinder? finder;

  final AssetInfo info;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusSm),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Vb.radiusSm),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40, maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconForKind(info.kind), size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: findText(
                    finder,
                    info.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatBytes(info.size),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Uploads in progress or failed, shown above the formatting bar. Failed ones keep their
/// file so Retry works.
class UploadTray extends StatelessWidget {
  const UploadTray({super.key, required this.repo});

  final AssetsRepository repo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final tasks = repo.uploads;
        if (tasks.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            Vb.space4,
            Vb.space2,
            Vb.space4,
            Vb.space2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final t in tasks) _UploadRow(task: t, repo: repo)],
          ),
        );
      },
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.task, required this.repo});

  final UploadTask task;
  final AssetsRepository repo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;
    final failed = task.state == UploadState.failed;
    final fg = failed ? (task.offline ? vb.warning : scheme.error) : vb.info;
    final bg = failed
        ? (task.offline ? vb.warningContainer : scheme.errorContainer)
        : vb.infoContainer;

    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: Vb.space1),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Vb.radiusMd),
        ),
        child: Row(
          children: [
            if (failed)
              Icon(
                task.offline ? LucideIcons.cloudOff : LucideIcons.triangleAlert,
                size: 18,
                color: fg,
              )
            else
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
            const SizedBox(width: Vb.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed
                        ? 'Couldn’t upload ${task.name}'
                        : 'Uploading ${task.name}…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  Text(
                    failed
                        ? (task.error ?? 'Something went wrong')
                        : formatBytes(task.bytes.length),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (failed) ...[
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: fg,
                  minimumSize: const Size(48, 40),
                ),
                onPressed: () => repo.retry(task),
                child: const Text('Retry'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                iconSize: 18,
                icon: Icon(LucideIcons.x, color: scheme.onSurfaceVariant),
                onPressed: () => repo.dismiss(task),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
