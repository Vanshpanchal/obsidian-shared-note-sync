import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../theme/vb_theme.dart';
import 'asset_widgets.dart';
import 'files_screen.dart';

/// One attachment: images zoom, everything else gets a card with Share / Open in…
class AssetViewerScreen extends StatefulWidget {
  const AssetViewerScreen({
    super.key,
    required this.assets,
    required this.info,
    this.onInsert,
  });

  final AssetsRepository assets;
  final AssetInfo info;
  final void Function(AssetInfo info)? onInsert;

  @override
  State<AssetViewerScreen> createState() => _AssetViewerScreenState();
}

class _AssetViewerScreenState extends State<AssetViewerScreen> {
  // Only fetched when needed (sharing): pictures are shown through the image cache, and
  // other files don't need their bytes until the user shares or opens them.
  Future<Uint8List>? _bytesFuture;
  Future<Uint8List> get _bytes =>
      _bytesFuture ??= widget.assets.bytes(widget.info);
  int _attempt = 0;
  bool _sharing = false;

  AssetInfo get info => widget.info;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext context) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    // iPad/macOS anchor the share sheet to a rectangle.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final data = await _bytes;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(data, name: info.name, mimeType: info.mimeType),
          ],
          fileNameOverrides: [info.name],
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _toast('Couldn’t share: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: info.link));
    _toast('Copied ${info.link}');
  }

  Future<void> _delete() async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${info.name}?'),
        content: const Text(
          'It’s removed from the server and from the Shared/assets folder in your vault. '
          'Links to it in your notes will stop working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.assets.delete(info);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _toast('Couldn’t delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      formatBytes(info.size),
      FilesScreen.when(info.modified),
    ].where((s) => s.isNotEmpty).join(' · ');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(LucideIcons.arrowLeft, color: scheme.onSurface),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Share',
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.share2),
              onPressed: () => _share(context),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) {
              switch (v) {
                case 'insert':
                  widget.onInsert?.call(info);
                  Navigator.popUntil(context, (r) => r.isFirst);
                case 'copy':
                  _copyLink();
                case 'delete':
                  _delete();
              }
            },
            itemBuilder: (_) => [
              if (widget.onInsert != null)
                const PopupMenuItem(
                  value: 'insert',
                  child: Text('Insert link in note'),
                ),
              const PopupMenuItem(value: 'copy', child: Text('Copy link')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: scheme.error)),
              ),
            ],
          ),
        ],
      ),
      body: info.isImage ? _image(context, meta) : _file(context, meta),
    );
  }

  Widget _image(BuildContext context, String meta) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: Center(
              child: Image(
                key: ValueKey('${info.cacheKey}#$_attempt'),
                image: widget.assets.imageFor(info),
                fit: BoxFit.contain,
                frameBuilder: (context, child, frame, sync) =>
                    frame == null && !sync
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(strokeWidth: 2),
                          const SizedBox(height: Vb.space4),
                          Text(
                            'Loading ${formatBytes(info.size)}…',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      )
                    : child,
                errorBuilder: (context, error, _) => _failed(context, error),
              ),
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            Vb.space4,
            Vb.space3,
            Vb.space4,
            Vb.space3 + MediaQuery.paddingOf(context).bottom,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Text(meta, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  Widget _file(
    BuildContext context,
    String meta, {
    bool cannotPreview = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Vb.space8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Icon(
                    iconForKind(info.kind),
                    size: 36,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: Vb.space5),
              Text(
                info.name,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                cannotPreview
                    ? 'This picture can’t be previewed here.\n$meta'
                    : meta,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontSize: 13,
                  height: 18 / 13,
                ),
              ),
              const SizedBox(height: Vb.space6),
              Builder(
                builder: (context) => FilledButton.icon(
                  onPressed: _sharing ? null : () => _share(context),
                  icon: const Icon(LucideIcons.share2, size: 18),
                  label: const Text('Share or open in…'),
                ),
              ),
              const SizedBox(height: Vb.space2),
              OutlinedButton.icon(
                onPressed: _copyLink,
                icon: const Icon(LucideIcons.link, size: 18),
                label: Text(
                  'Copy link',
                  style: TextStyle(color: scheme.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _failed(BuildContext context, Object error) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Vb.space8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.cloudOff,
              size: 32,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: Vb.space3),
            Text('Couldn’t load this file', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Vb.space4),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
              onPressed: () async {
                await widget.assets.evictImage(info);
                if (mounted) setState(() => _attempt++);
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
