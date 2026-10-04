import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../theme/vb_theme.dart';
import 'asset_viewer_screen.dart';
import 'asset_widgets.dart';
import 'attach_flow.dart';
import 'widgets.dart';

/// Everything in the attachments bucket (`Shared/assets` in the vault).
///
/// Normal mode: tap a file to open it. [pickMode]: tapping returns the file, used by
/// "Already uploaded" in the attach sheet. [onInsert] puts a link into the open note.
class FilesScreen extends StatefulWidget {
  const FilesScreen({
    super.key,
    required this.assets,
    this.pickMode = false,
    this.onInsert,
  });

  final AssetsRepository assets;
  final bool pickMode;
  final void Function(AssetInfo info)? onInsert;

  static String when(DateTime? d) {
    if (d == null) return '';
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final t =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '${m[d.month - 1]} ${d.day}, $t';
  }

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  AssetsRepository get assets => widget.assets;
  bool get pickMode => widget.pickMode;
  void Function(AssetInfo info)? get onInsert => widget.onInsert;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  /// Every word must appear in the name, the extension/kind ("pdf", "image") or the size text.
  List<AssetInfo> _filter(List<AssetInfo> all) {
    final words = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    if (words.isEmpty) return all;
    return [
      for (final f in all)
        if (words.every((w) {
          final hay = '${f.name} ${f.kind.name} ${f.mimeType}'.toLowerCase();
          return hay.contains(w);
        }))
          f,
    ];
  }

  /// [name] with the matched search words in bold.
  TextSpan _highlight(String name, TextStyle base, ColorScheme scheme) {
    final words = _query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return TextSpan(text: name, style: base);
    final re = RegExp(words.map(RegExp.escape).join('|'), caseSensitive: false);
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in re.allMatches(name)) {
      if (m.start > at) spans.add(TextSpan(text: name.substring(at, m.start)));
      spans.add(
        TextSpan(
          text: m[0],
          style: TextStyle(
            backgroundColor: scheme.primary.withValues(alpha: 0.25),
            color: scheme.onSurface,
          ),
        ),
      );
      at = m.end;
    }
    if (at < name.length) spans.add(TextSpan(text: name.substring(at)));
    return TextSpan(style: base, children: spans);
  }

  void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _add(BuildContext context) async {
    final saved = await attachFiles(context, assets, false);
    if (!context.mounted || saved.isEmpty) return;
    if (pickMode) {
      Navigator.pop(context, saved.first);
    } else if (onInsert != null) {
      _toast(
        context,
        saved.length == 1
            ? 'Uploaded ${saved.first.name}'
            : 'Uploaded ${saved.length} files',
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, AssetInfo info) async {
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
    if (ok != true || !context.mounted) return;
    try {
      await assets.delete(info);
      if (context.mounted) _toast(context, 'Deleted ${info.name}');
    } catch (e) {
      if (context.mounted) _toast(context, 'Couldn’t delete: $e');
    }
  }

  Future<void> _copyLink(BuildContext context, AssetInfo info) async {
    await Clipboard.setData(ClipboardData(text: info.link));
    if (context.mounted) _toast(context, 'Copied ${info.link}');
  }

  void _open(BuildContext context, AssetInfo info) {
    if (pickMode) {
      Navigator.pop(context, info);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AssetViewerScreen(assets: assets, info: info, onInsert: onInsert),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: assets,
      builder: (context, _) {
        final all = assets.files;
        final files = _filter(all);
        return PopScope(
          canPop: !_searching,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeSearch();
          },
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: _searching ? 'Close search' : 'Back',
                icon: Icon(
                  _searching ? LucideIcons.x : LucideIcons.arrowLeft,
                  color: scheme.onSurface,
                ),
                onPressed: _searching
                    ? _closeSearch
                    : () => Navigator.maybePop(context),
              ),
              title: Text(pickMode ? 'Choose a file' : 'Files'),
              actions: [
                if (!_searching)
                  IconButton(
                    tooltip: 'Search files',
                    icon: const Icon(LucideIcons.search),
                    onPressed: all.isEmpty ? null : _openSearch,
                  ),
                if (assets.loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: Vb.space4),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(LucideIcons.refreshCw),
                    onPressed: assets.refresh,
                  ),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _add(context),
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              elevation: 0,
              focusElevation: 0,
              hoverElevation: 0,
              highlightElevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Vb.radiusLg),
              ),
              icon: const Icon(LucideIcons.plus, size: 20),
              label: const Text(
                'Add file',
                style: TextStyle(
                  fontFamily: Vb.sans,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            body: Column(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _searching
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Vb.space4,
                            Vb.space1,
                            Vb.space4,
                            Vb.space2,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              VbSearchField(
                                controller: _searchController,
                                focusNode: _searchFocus,
                                autofocus: true,
                                hint: 'Search by name or type',
                                onChanged: (v) =>
                                    setState(() => _query = v.trim()),
                              ),
                              if (_query.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    Vb.space1,
                                    Vb.space2,
                                    0,
                                    0,
                                  ),
                                  child: Text(
                                    files.isEmpty
                                        ? 'No matches'
                                        : '${files.length} of ${all.length} file${all.length == 1 ? '' : 's'}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                if (assets.offline) _banner(context, offline: true),
                if (assets.error != null) _banner(context, offline: false),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: assets.refresh,
                    child: files.isEmpty
                        ? (all.isNotEmpty
                              ? _noMatches(context)
                              : _empty(context))
                        : ListView.builder(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: files.length + 1,
                            itemBuilder: (context, i) {
                              if (i == files.length) return _footer(context);
                              return _row(context, files[i]);
                            },
                          ),
                  ),
                ),
                UploadTray(repo: assets),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _noMatches(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        Vb.space10,
        96,
        Vb.space10,
        Vb.space10,
      ),
      children: [
        Icon(LucideIcons.searchX, size: 32, color: scheme.onSurfaceVariant),
        const SizedBox(height: Vb.space4),
        Text(
          'No files match “$_query”',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium!.copyWith(fontSize: 18),
        ),
        const SizedBox(height: 6),
        Text(
          'Try part of the name, or a type like “pdf” or “image”.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AssetInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: InkWell(
        onTap: () => _open(context, info),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Vb.space4, 10, Vb.space1, 10),
          child: Row(
            children: [
              AssetThumb(info: info, repo: assets),
              const SizedBox(width: Vb.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      _highlight(
                        info.name,
                        theme.textTheme.bodyLarge!.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        scheme,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        formatBytes(info.size),
                        FilesScreen.when(info.modified),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (pickMode)
                Padding(
                  padding: const EdgeInsets.only(right: Vb.space3),
                  child: Icon(
                    LucideIcons.chevronRight,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Actions for ${info.name}',
                  icon: const Icon(LucideIcons.ellipsisVertical),
                  onSelected: (v) {
                    switch (v) {
                      case 'insert':
                        onInsert?.call(info);
                        Navigator.maybePop(context);
                      case 'copy':
                        _copyLink(context, info);
                      case 'delete':
                        _confirmDelete(context, info);
                    }
                  },
                  itemBuilder: (_) => [
                    if (onInsert != null)
                      const PopupMenuItem(
                        value: 'insert',
                        child: Text('Insert link in note'),
                      ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy link'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Vb.space6),
    child: Text(
      '${assets.files.length} file${assets.files.length == 1 ? '' : 's'} · '
      '${formatBytes(assets.totalBytes)} · up to ${formatBytes(assets.maxBytes)} each',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loadingFirst = !assets.loaded && assets.loading;
    return ListView(
      // Scrollable so pull-to-refresh works on an empty list too.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        Vb.space10,
        120,
        Vb.space10,
        Vb.space10,
      ),
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Icon(
              assets.configured ? LucideIcons.files : LucideIcons.cloudOff,
              size: 30,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: Vb.space4),
        Text(
          loadingFirst
              ? 'Loading files…'
              : assets.configured
              ? 'No files yet'
              : 'Not connected',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium!.copyWith(fontSize: 18),
        ),
        const SizedBox(height: 6),
        Text(
          assets.configured
              ? 'Add photos, PDFs and other files. They sync to the Shared/assets folder in your vault, '
                    'so you can link them with [[wikilinks]].'
              : 'Set up the endpoint and API key in Settings to use files.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _banner(BuildContext context, {required bool offline}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;
    final fg = offline ? vb.warning : scheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Vb.space4, vertical: 10),
      decoration: BoxDecoration(
        color: offline ? vb.warningContainer : scheme.errorContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            offline ? LucideIcons.cloudOff : LucideIcons.triangleAlert,
            size: 18,
            color: fg,
          ),
          const SizedBox(width: Vb.space3),
          Expanded(
            child: Text(
              offline
                  ? 'You’re offline. Showing the last list; pictures you’ve opened still load.'
                  : (assets.error ?? ''),
              style: theme.textTheme.bodySmall!.copyWith(
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: fg,
              minimumSize: const Size(48, 36),
            ),
            onPressed: assets.refresh,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
