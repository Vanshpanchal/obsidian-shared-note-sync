import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable, RenderObject;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/settings_store.dart';
import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../data/shared_repository.dart';
import '../export/note_pdf.dart';
import '../markdown/find_in_note.dart';
import '../markdown/obsidian_markdown.dart';
import '../theme/vb_theme.dart';
import 'asset_viewer_screen.dart';
import 'asset_widgets.dart';
import 'attach_flow.dart';
import 'conflict_copies_screen.dart';
import 'files_screen.dart';
import 'markdown_editing_controller.dart';
import 'conflict_screen.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';
import 'status_sheet.dart';
import 'widgets.dart';

class SharedScreen extends StatefulWidget {
  const SharedScreen({
    super.key,
    required this.repo,
    required this.settings,
    required this.assets,
  });

  final SharedRepository repo;
  final SettingsStore settings;
  final AssetsRepository assets;

  @override
  State<SharedScreen> createState() => _SharedScreenState();
}

class _SharedScreenState extends State<SharedScreen>
    with WidgetsBindingObserver {
  late final MarkdownEditingController _controller;
  final _focus = FocusNode();
  final _finder = NoteFinder();
  final _findController = TextEditingController();
  final _findFocus = FocusNode();
  bool _finding = false;
  bool _preview = false;
  bool _conflictOpen = false;
  bool _loading = false;
  Timer? _loadingTimeout;

  SharedRepository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _controller = MarkdownEditingController(text: repo.content);
    repo.addListener(_onRepoChanged);
    WidgetsBinding.instance.addObserver(this);
    // First launch with nothing cached: show the skeleton until the first pull lands.
    _loading =
        widget.settings.isConfigured &&
        repo.version == 0 &&
        repo.content.isEmpty;
    if (_loading) {
      _loadingTimeout = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _loading = false);
      });
    }
    if (widget.settings.isConfigured) unawaited(widget.assets.refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.settings.isConfigured) _openOnboarding();
    });
  }

  @override
  void dispose() {
    _loadingTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    repo.removeListener(_onRepoChanged);
    _controller.dispose();
    _focus.dispose();
    _finder.dispose();
    _findController.dispose();
    _findFocus.dispose();
    _editScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(repo.flush());
      case AppLifecycleState.resumed:
        unawaited(repo.pull());
        unawaited(widget.assets.refresh());
      default:
        break;
    }
  }

  void _onRepoChanged() {
    // Content replaced from the server (pull / "use server's"): update the editor.
    if (_controller.text != repo.content) {
      final offset = _controller.selection.baseOffset.clamp(
        0,
        repo.content.length,
      );
      _controller.value = TextEditingValue(
        text: repo.content,
        selection: TextSelection.collapsed(offset: offset),
      );
    }
    if (_loading &&
        (repo.version > 0 ||
            repo.status == SyncStatus.offline ||
            repo.status == SyncStatus.error ||
            repo.status == SyncStatus.conflict ||
            repo.status == SyncStatus.notConfigured)) {
      _loading = false;
    }
    if (repo.status == SyncStatus.conflict && !_conflictOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showConflict());
    }
    if (mounted) setState(() {});
  }

  Future<void> _showConflict() async {
    final server = repo.conflict;
    if (server == null || _conflictOpen || !mounted) return;
    _conflictOpen = true;
    final choice = await showConflictScreen(
      context,
      server: server,
      mine: repo.content,
      baseVersion: repo.version,
    );
    _conflictOpen = false;
    if (choice != null) await repo.resolveConflict(choice);
  }

  Future<void> _openOnboarding() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(settings: widget.settings),
      ),
    );
    if (saved == true) await _reconfigure();
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: widget.settings,
          repo: repo,
          assets: widget.assets,
        ),
      ),
    );
    if (changed != true) return;
    await _reconfigure();
    if (!widget.settings.isConfigured && mounted) _openOnboarding();
  }

  /// The endpoint or key changed: re-sync the note and re-list the attachments.
  Future<void> _reconfigure() async {
    widget.assets.reconfigure();
    await repo.reconfigure();
  }

  void _onChipTap() {
    switch (repo.status) {
      case SyncStatus.conflict:
        _showConflict();
      case SyncStatus.notConfigured:
        _openOnboarding();
      case SyncStatus.pending:
        // Unsaved: tapping saves right now (autosave fires 2 s after typing stops).
        unawaited(repo.flush());
      default:
        showStatusSheet(
          context,
          repo: repo,
          settings: widget.settings,
          onRetry: () => unawaited(
            repo.status == SyncStatus.pending ? repo.flush() : repo.pull(),
          ),
          onOpenSettings: _openSettings,
        );
    }
  }

  late final _callbacks = ObsidianCallbacks(
    finder: _finder,
    onExternalLink: (href) => _launch(Uri.tryParse(href)),
    // Opens the note in Obsidian (uses the last opened vault).
    onWikiLink: (target) {
      // A link to an attachment opens it here; anything else is a note in Obsidian.
      final asset = widget.assets.find(target);
      if (asset != null) return _openAsset(asset);
      final file = target.split('#').first;
      if (file.isEmpty)
        return _toast('Link to a heading in this note: ${target.substring(1)}');
      _launch(
        Uri(scheme: 'obsidian', host: 'open', queryParameters: {'file': file}),
      );
    },
    onTag: (tag) => _toast('#$tag'),
    embedBuilder: (context, target, width) {
      final info = widget.assets.find(target);
      if (info == null) return null;
      if (info.isImage) {
        return AssetImageEmbed(
          info: info,
          repo: widget.assets,
          width: width,
          onTap: () => _openAsset(info),
        );
      }
      return AssetFileChip(
        info: info,
        onTap: () => _openAsset(info),
        finder: _finder,
      );
    },
  );

  void _openAsset(AssetInfo info) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AssetViewerScreen(
          assets: widget.assets,
          info: info,
          onInsert: (i) => _insertLinks([i]),
        ),
      ),
    );
  }

  void _openFiles() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilesScreen(
          assets: widget.assets,
          onInsert: (i) => _insertLinks([i]),
        ),
      ),
    );
  }

  /// Attach: pick (photos, camera, files or an already-uploaded file), upload, then put
  /// the links into the note where the cursor is.
  Future<void> _attach() async {
    final saved = await attachFiles(context, widget.assets, true);
    if (!mounted || saved.isEmpty) return;
    _insertLinks(saved);
  }

  /// Inserts `![[image.png]]` / `[[file.pdf]]` lines at the cursor (or at the end).
  void _insertLinks(List<AssetInfo> files) {
    if (files.isEmpty) return;
    final t = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    final before = t.substring(0, start);
    final after = t.substring(end);
    final lead = before.isNotEmpty && !before.endsWith('\n') ? '\n' : '';
    final block = '$lead${files.map((f) => f.link).join('\n')}\n';
    _apply(
      '$before$block$after',
      TextSelection.collapsed(offset: before.length + block.length),
    );
    if (_preview) setState(() => _preview = false);
    _toast(
      files.length == 1
          ? 'Link to ${files.first.name} added to the note'
          : '${files.length} links added to the note',
    );
  }

  Future<void> _launch(Uri? uri) async {
    if (uri == null) return;
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    _toast(
      uri.scheme == 'obsidian'
          ? 'Obsidian is not installed'
          : "Can't open $uri",
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openFind() {
    setState(() => _finding = true);
    _findFocus.requestFocus();
  }

  void _closeFind() {
    _findController.clear();
    _finder.clear();
    _controller.clearFind();
    _findFocus.unfocus();
    setState(() => _finding = false);
  }

  final _editScroll = ScrollController();
  final _editFieldKey = GlobalKey();

  /// Sends the query to whichever tab is showing; the other tab's highlights are cleared.
  void _applyFind(String query) {
    final q = query.trim();
    if (_preview) {
      _controller.clearFind();
      _finder.setQuery(q);
    } else {
      _finder.clear();
      _controller.setFind(q);
      _revealEditMatch();
    }
  }

  int get _findCount =>
      _preview ? _finder.count : _controller.findMatches().length;
  int get _findIndex => _preview ? _finder.current : _controller.findCurrent;

  void _findStep(int by) {
    if (_preview) {
      by > 0 ? _finder.next() : _finder.previous();
    } else {
      _controller.stepFind(by);
      _revealEditMatch();
    }
  }

  RenderEditable? _editable() {
    RenderEditable? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderEditable) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    _editFieldKey.currentContext?.findRenderObject()?.visitChildren(visit);
    return found;
  }

  /// Scrolls the editor so the selected match sits about a third of the way down. The
  /// caret isn't moved (focus stays in the search box), so this asks the editor's real
  /// text layout where the match is rather than estimating it.
  void _revealEditMatch() {
    final m = _controller.currentFindMatch;
    if (m == null || !_editScroll.hasClients) return;
    // The highlight changes no metrics, but the field may still be laying out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final editable = _editable();
      if (!mounted ||
          editable == null ||
          !editable.hasSize ||
          !_editScroll.hasClients)
        return;
      final rect = editable.getLocalRectForCaret(TextPosition(offset: m.start));
      final pos = _editScroll.position;
      final target = (pos.pixels + rect.top - pos.viewportDimension * 0.3)
          .clamp(0.0, pos.maxScrollExtent);
      _editScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _findBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextFieldTapRegion(
      child: ListenableBuilder(
        listenable: Listenable.merge([_finder, _controller]),
        builder: (context, _) {
          final typed = _findController.text.trim().isNotEmpty;
          final count = _findCount;
          // Nothing to count when there are no matches: the disabled arrows say it.
          final counter = !typed || count == 0
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: Vb.space1),
                  child: Text(
                    '${_findIndex + 1}/$count',
                    style: theme.textTheme.labelMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                );
          Widget nav(IconData icon, String tip, VoidCallback? onTap) =>
              IconButton.filledTonal(
                tooltip: tip,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(40, 40),
                  backgroundColor: scheme.surfaceContainerHigh,
                  disabledBackgroundColor: scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Vb.radiusMd),
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                icon: Icon(icon, size: 20),
                onPressed: onTap,
              );
          return Container(
            padding: const EdgeInsets.fromLTRB(
              Vb.space4,
              Vb.space1,
              Vb.space2,
              Vb.space2,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: VbSearchField(
                    controller: _findController,
                    focusNode: _findFocus,
                    autofocus: true,
                    hint: 'Find in note',
                    trailing: counter,
                    onChanged: _applyFind,
                    // Enter jumps to the next match; the keyboard stays up.
                    onSubmitted: (_) {
                      _findStep(1);
                      _findFocus.requestFocus();
                    },
                  ),
                ),
                const SizedBox(width: Vb.space2),
                nav(
                  LucideIcons.chevronUp,
                  'Previous match',
                  count == 0 ? null : () => _findStep(-1),
                ),
                const SizedBox(width: Vb.space1),
                nav(
                  LucideIcons.chevronDown,
                  'Next match',
                  count == 0 ? null : () => _findStep(1),
                ),
                TextButton(onPressed: _closeFind, child: const Text('Done')),
              ],
            ),
          );
        },
      ),
    );
  }

  bool _exporting = false;

  /// Renders the preview (attachments included) to a PDF and opens the share sheet,
  /// which also offers "Save to Files".
  Future<void> _exportPdf() async {
    if (_exporting) return;
    if (repo.content.trim().isEmpty) return _toast('Nothing to export yet');
    setState(() => _exporting = true);
    _toast('Preparing PDF…');
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final bytes = await renderNotePdf(
        context: context,
        markdown: repo.content,
        assets: widget.assets,
        callbacks: _callbacks.withoutFinder(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              name: 'shared.pdf',
              mimeType: 'application/pdf',
            ),
          ],
          fileNameOverrides: ['shared.pdf'],
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _toast('Couldn’t export PDF: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- formatting toolbar ----

  void _apply(String text, TextSelection selection) {
    _controller.value = TextEditingValue(text: text, selection: selection);
    repo.edit(text);
    _focus.requestFocus();
  }

  void _wrap(String left, [String? right]) {
    right ??= left;
    final t = _controller.text;
    final sel = _controller.selection;
    final s = sel.isValid ? sel.start : t.length;
    final e = sel.isValid ? sel.end : t.length;
    final inner = t.substring(s, e);
    _apply(
      t.replaceRange(s, e, '$left$inner$right'),
      inner.isEmpty
          ? TextSelection.collapsed(offset: s + left.length)
          : TextSelection(
              baseOffset: s + left.length,
              extentOffset: s + left.length + inner.length,
            ),
    );
  }

  void _prefixLine(String prefix) {
    final t = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : t.length;
    final lineStart = at == 0 ? 0 : t.lastIndexOf('\n', at - 1) + 1;
    _apply(
      t.replaceRange(lineStart, lineStart, prefix),
      TextSelection.collapsed(offset: at + prefix.length),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) => IconButton(
    tooltip: label,
    iconSize: 20,
    constraints: const BoxConstraints(minWidth: 40, minHeight: Vb.touch),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: onTap,
  );

  // ---- build ----

  /// First load with nothing cached and no verdict from the server yet.
  bool get _showSkeleton =>
      _loading &&
      repo.version == 0 &&
      repo.content.isEmpty &&
      (repo.status == SyncStatus.saved || repo.status == SyncStatus.saving);

  bool get _wrongKey =>
      repo.status == SyncStatus.error &&
      (repo.errorMessage ?? '').toLowerCase().contains('api key');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Vb.space4,
        title: Row(
          children: [
            const VbMark(size: 22),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'shared.md',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (!_finding)
            IconButton(
              tooltip: 'Find in note',
              icon: const Icon(LucideIcons.search),
              onPressed: _openFind,
            ),
          StatusChip(
            status: repo.status,
            loading: _showSkeleton,
            pendingCount: repo.dirty ? 1 : 0,
            onTap: _onChipTap,
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) {
              if (v == 'settings') _openSettings();
              if (v == 'files') _openFiles();
              if (v == 'copies') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConflictCopiesScreen(repo: repo),
                  ),
                );
              }
              if (v == 'pull') repo.pull();
              if (v == 'pdf') _exportPdf();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'files', child: Text('Files')),
              PopupMenuItem(value: 'pdf', child: Text('Export as PDF')),
              PopupMenuItem(value: 'pull', child: Text('Pull from server')),
              PopupMenuItem(value: 'copies', child: Text('Conflict copies')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
          const SizedBox(width: Vb.space1),
        ],
      ),
      body: Column(
        children: [
          if (repo.status == SyncStatus.offline) _offlineBanner(context),
          if (_wrongKey) _wrongKeyBanner(context),
          // In a short window (landscape) with the keyboard up there is barely room for the
          // text, so the tab row steps aside until the keyboard is dismissed.
          if (!(MediaQuery.viewInsetsOf(context).bottom > 0 &&
              MediaQuery.sizeOf(context).height < 520))
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Vb.space4,
                vertical: Vb.space2,
              ),
              child: VbSegmented<bool>(
                semanticLabel: 'View',
                value: _preview,
                onChanged: (v) {
                  if (v) FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _preview = v);
                  if (_finding) _applyFind(_findController.text);
                },
                options: const [
                  VbSegment(false, 'Edit', icon: LucideIcons.pencil),
                  VbSegment(true, 'Preview', icon: LucideIcons.eye),
                ],
              ),
            ),
          if (_finding) _findBar(context),
          UploadTray(repo: widget.assets),
          Expanded(
            child: _showSkeleton
                ? const _Skeleton()
                : _preview
                ? _previewView(context)
                : _editView(context),
          ),
        ],
      ),
      backgroundColor: scheme.surface,
    );
  }

  Widget _offlineBanner(BuildContext context) {
    final theme = Theme.of(context);
    final vb = context.vb;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      decoration: BoxDecoration(
        color: vb.warningContainer,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.cloudOff, size: 20, color: vb.warning),
          ),
          const SizedBox(width: Vb.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You’re offline',
                  style: theme.textTheme.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  repo.dirty
                      ? '1 change is safe on this phone and will upload when you’re back.'
                      : 'Showing the last synced copy. Retrying automatically.',
                  style: theme.textTheme.bodySmall!.copyWith(
                    fontSize: 13,
                    height: 18 / 13,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: vb.warning,
              minimumSize: const Size(48, 40),
              textStyle: const TextStyle(
                fontFamily: Vb.sans,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: repo.pull,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _wrongKeyBanner(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.keyRound, size: 20, color: scheme.error),
          ),
          const SizedBox(width: Vb.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The server didn’t accept your API key',
                  style: theme.textTheme.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Syncing is paused. Your edits are kept on this phone until the key is fixed.',
                  style: theme.textTheme.bodySmall!.copyWith(
                    fontSize: 13,
                    height: 18 / 13,
                  ),
                ),
                const SizedBox(height: Vb.space2),
                Row(
                  children: [
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.surface,
                        minimumSize: const Size(64, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontFamily: Vb.sans,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: _openOnboarding,
                      child: const Text('Update key'),
                    ),
                    const SizedBox(width: Vb.space2),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        minimumSize: const Size(64, 36),
                        textStyle: const TextStyle(
                          fontFamily: Vb.sans,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: repo.pull,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewView(BuildContext context) {
    final theme = Theme.of(context);
    // Rebuild when the attachment list changes so `![[image.png]]` turns into the picture.
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assets, _finder.query]),
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Vb.reading),
          child: ObsidianMarkdownView(
            data: repo.content,
            callbacks: _callbacks,
            padding: const EdgeInsets.fromLTRB(
              Vb.space4,
              Vb.space3,
              Vb.space4,
              0,
            ),
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(0, Vb.space8, 0, Vb.space10),
              child: Column(
                children: [
                  Icon(
                    LucideIcons.check,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    repo.version == 0
                        ? 'End of shared.md'
                        : 'End of shared.md · v${repo.version}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _editView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;
    final empty = repo.content.isEmpty;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final saveable =
        repo.dirty ||
        repo.status == SyncStatus.error ||
        repo.status == SyncStatus.offline;

    final field = TextField(
      key: _editFieldKey,
      scrollController: _editScroll,
      controller: _controller,
      focusNode: _focus,
      onChanged: repo.edit,
      // Tap anywhere outside (tabs, app bar, banners) to drop the keyboard. The toolbar
      // and floating buttons are wrapped in TextFieldTapRegion so they don't count.
      onTapOutside: (_) => _focus.unfocus(),
      maxLines: null,
      expands: true,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      cursorColor: scheme.primary,
      style: context.reading.editor,
      decoration: InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(
          Vb.space4,
          Vb.space2,
          Vb.space4,
          Vb.space2,
        ),
        hintText: 'Write in Markdown…',
        hintStyle: context.reading.editor.copyWith(color: vb.inkFaint),
      ),
    );

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              field,
              if (!keyboardUp)
                Positioned(
                  right: Vb.space4,
                  bottom: Vb.space6,
                  child: TextFieldTapRegion(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _attachFab(context),
                        const SizedBox(height: Vb.space3),
                        _saveFab(context, saveable),
                      ],
                    ),
                  ),
                ),
              if (empty)
                Positioned.fill(
                  child: IgnorePointer(
                    // The full illustration needs ~240 px. With the keyboard up there may be
                    // less, so the top gap shrinks first and the picture drops out last.
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final room = box.maxHeight;
                        final compact = room < 240;
                        final top = (room - 240).clamp(0.0, 130.0);
                        return Padding(
                          padding: EdgeInsets.only(
                            top: compact ? Vb.space4 : top,
                          ),
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Vb.space10,
                              ),
                              // Never scrolls: it only makes a too-tall block clip, not overflow.
                              child: SingleChildScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!compact) ...[
                                      Container(
                                        width: 72,
                                        height: 72,
                                        decoration: BoxDecoration(
                                          color: scheme.surfaceContainerLow,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: scheme.outlineVariant,
                                          ),
                                        ),
                                        child: const Center(
                                          child: VbMark(size: 44),
                                        ),
                                      ),
                                      const SizedBox(height: Vb.space4),
                                    ],
                                    Text(
                                      'Nothing here yet.',
                                      style: theme.textTheme.titleMedium!
                                          .copyWith(
                                            fontSize: 18,
                                            height: 25 / 18,
                                          ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Start typing – it saves itself.',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyLarge!
                                          .copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: Vb.space3),
                                    Text(
                                      'Synced with Shared/shared.md in your vault',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (keyboardUp) TextFieldTapRegion(child: _toolbar(context)),
      ],
    );
  }

  /// Small secondary action above the Save FAB: attach a photo or file.
  Widget _attachFab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Attach file',
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Vb.radiusLg),
          side: BorderSide(color: scheme.outline),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Vb.radiusLg),
          onTap: _attach,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              LucideIcons.paperclip,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 56 px Save FAB shown while the keyboard is down; disabled (ink-faint) when saved.
  Widget _saveFab(BuildContext context, bool saveable) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    return Semantics(
      button: true,
      enabled: saveable,
      label: 'Save now',
      child: Material(
        color: saveable ? scheme.primary : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Vb.radiusLg),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Vb.radiusLg),
            boxShadow: saveable
                ? [
                    BoxShadow(
                      color: vb.shadowFab,
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Vb.radiusLg),
            onTap: saveable ? () => repo.flush() : null,
            child: Icon(
              LucideIcons.save,
              size: 22,
              color: saveable ? scheme.onPrimary : vb.inkFaint,
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final saveable =
        repo.dirty ||
        repo.status == SyncStatus.error ||
        repo.status == SyncStatus.offline;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: Border(top: BorderSide(color: scheme.outlineVariant)),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Vb.space1),
                  children: [
                    _tool(LucideIcons.paperclip, 'Attach file', _attach),
                    _tool(
                      LucideIcons.heading,
                      'Heading',
                      () => _prefixLine('## '),
                    ),
                    _tool(LucideIcons.bold, 'Bold', () => _wrap('**')),
                    _tool(LucideIcons.italic, 'Italic', () => _wrap('*')),
                    _tool(
                      LucideIcons.squareCheck,
                      'Task',
                      () => _prefixLine('- [ ] '),
                    ),
                    _tool(LucideIcons.link, 'Link', () => _wrap('[', '](url)')),
                    IconButton(
                      tooltip: 'Wikilink',
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: Vb.touch,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => _wrap('[[', ']]'),
                      icon: Text(
                        '[[ ]]',
                        style: TextStyle(
                          fontFamily: Vb.mono,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -1,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    _tool(LucideIcons.code, 'Code', () => _wrap('`')),
                    _tool(
                      LucideIcons.quote,
                      'Callout',
                      () => _prefixLine('> [!note] '),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 28, color: scheme.outlineVariant),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Vb.space2),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
                    shape: const StadiumBorder(),
                    backgroundColor: saveable
                        ? scheme.primary
                        : scheme.surfaceContainerHigh,
                    foregroundColor: saveable ? scheme.onPrimary : vb.inkFaint,
                    textStyle: const TextStyle(
                      fontFamily: Vb.sans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    shadowColor: vb.shadowFab,
                  ),
                  onPressed: () => repo.flush(),
                  icon: const Icon(LucideIcons.save, size: 18),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder shown while the very first pull is in flight.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;

    Widget bar(double w, double h, {bool strong = false, double r = 4}) =>
        FractionallySizedBox(
          widthFactor: w,
          alignment: Alignment.centerLeft,
          child: Container(
            height: h,
            decoration: BoxDecoration(
              color: strong ? vb.skeletonStrong : vb.skeleton,
              borderRadius: BorderRadius.circular(r),
            ),
          ),
        );

    Widget box(double w, double h, {bool strong = false, double r = 4}) =>
        Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: strong ? vb.skeletonStrong : vb.skeleton,
            borderRadius: BorderRadius.circular(r),
          ),
        );

    return Semantics(
      label: 'Loading shared.md',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Vb.space4,
          Vb.space3,
          Vb.space4,
          Vb.space6,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 132,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Vb.radiusMd),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      box(72, 12),
                      const SizedBox(width: 12),
                      box(56, 22, r: 999),
                      const SizedBox(width: 12),
                      box(64, 22, r: 999),
                    ],
                  ),
                  Row(
                    children: [
                      box(72, 12),
                      const SizedBox(width: 12),
                      box(120, 12),
                    ],
                  ),
                  Row(
                    children: [
                      box(72, 12),
                      const SizedBox(width: 12),
                      box(18, 18),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Vb.space5),
            bar(0.62, 26, strong: true, r: 6),
            const SizedBox(height: Vb.space5),
            bar(1, 14),
            const SizedBox(height: 12),
            bar(0.94, 14),
            const SizedBox(height: 12),
            bar(0.88, 14),
            const SizedBox(height: 12),
            bar(0.46, 14),
            const SizedBox(height: Vb.space5),
            Container(
              height: 84,
              decoration: BoxDecoration(
                color: vb.skeleton,
                borderRadius: BorderRadius.circular(Vb.radiusMd),
              ),
            ),
            const Spacer(),
            Center(
              child: Text(
                'Fetching shared.md…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
