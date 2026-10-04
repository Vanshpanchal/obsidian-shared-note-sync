import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/shared_api.dart';
import '../data/shared_repository.dart';
import '../theme/vb_theme.dart';
import 'widgets.dart';

/// Full-screen conflict resolution. Returns null if closed ("decide later");
/// the conflict stays open and the status chip can reopen this screen.
Future<ConflictChoice?> showConflictScreen(
  BuildContext context, {
  required SharedState server,
  required String mine,
  required int baseVersion,
}) {
  return Navigator.of(context).push<ConflictChoice>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          ConflictScreen(server: server, mine: mine, baseVersion: baseVersion),
    ),
  );
}

String? _time(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return null;
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class ConflictScreen extends StatelessWidget {
  const ConflictScreen({
    super.key,
    required this.server,
    required this.mine,
    required this.baseVersion,
  });

  final SharedState server;
  final String mine;
  final int baseVersion;

  Future<void> _keepMine(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _OverwriteDialog(server: server),
    );
    if (ok == true && context.mounted)
      Navigator.pop(context, ConflictChoice.keepMine);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;
    final t = _time(server.updatedAt);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close and decide later',
          icon: Icon(LucideIcons.x, color: scheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Resolve conflict'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Vb.space4),
            child: StatusChip(status: SyncStatus.conflict, onTap: null),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Vb.space4,
          Vb.space4,
          Vb.space4,
          Vb.space6,
        ),
        children: [
          Text(
            'This note changed elsewhere',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: Vb.space1),
          Text(
            'shared.md was saved on another device while you were editing. Nothing is lost until you choose.',
            style: theme.textTheme.bodyMedium!.copyWith(
              fontSize: 14,
              height: 20 / 14,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Vb.space3),
          _CopyCard(
            icon: LucideIcons.cloud,
            title: 'Server copy',
            meta:
                'Other device${t != null ? ' · $t' : ''} · v${server.version}',
            text: server.content,
            other: mine,
            highlight: vb.infoContainer,
          ),
          const SizedBox(height: Vb.space3),
          _CopyCard(
            icon: LucideIcons.smartphone,
            title: 'Your copy',
            meta: 'This device · from v$baseVersion',
            text: mine,
            other: server.content,
            highlight: scheme.primaryContainer,
          ),
          const SizedBox(height: Vb.space4),
          Text(
            'Choose what to keep',
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Vb.space2),
          _Choice(
            filled: true,
            icon: LucideIcons.copy,
            title: 'Save mine as copy',
            detail:
                'Loads the server copy. Yours goes to Conflict copies. Nothing is lost.',
            badge: 'Safest',
            onTap: () => Navigator.pop(context, ConflictChoice.saveMineAsCopy),
          ),
          const SizedBox(height: Vb.space2),
          _Choice(
            icon: LucideIcons.cloudDownload,
            title: "Use server's",
            emphasis: 'Discards',
            emphasisColor: vb.warning,
            detail: ' your edits made on this phone.',
            onTap: () => Navigator.pop(context, ConflictChoice.useServer),
          ),
          const SizedBox(height: Vb.space2),
          _Choice(
            danger: true,
            icon: LucideIcons.cloudUpload,
            title: 'Keep mine',
            emphasis: 'Overwrites',
            emphasisColor: scheme.error,
            detail: ' the server copy. You’ll confirm first.',
            onTap: () => _keepMine(context),
          ),
        ],
      ),
    );
  }
}

class _CopyCard extends StatelessWidget {
  const _CopyCard({
    required this.icon,
    required this.title,
    required this.meta,
    required this.text,
    required this.other,
    required this.highlight,
  });

  final IconData icon;
  final String title;
  final String meta;
  final String text;
  final String other;
  final Color highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final otherLines = other.split('\n').toSet();
    final lines = text.isEmpty ? <String>[] : text.split('\n');
    final mono = context.reading.code.copyWith(
      fontSize: 12.5,
      height: 20 / 12.5,
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: Vb.space2),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    meta,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: Vb.space2),
              child: lines.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '(empty)',
                        style: mono.copyWith(color: context.vb.inkFaint),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final l in lines)
                          Container(
                            color: otherLines.contains(l) ? null : highlight,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              l.isEmpty ? ' ' : l,
                              style: mono.copyWith(
                                color: otherLines.contains(l)
                                    ? scheme.onSurfaceVariant
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.emphasis,
    this.emphasisColor,
    this.badge,
    this.filled = false,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? emphasis;
  final Color? emphasisColor;
  final String? badge;
  final bool filled;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = filled
        ? scheme.primary
        : danger
        ? scheme.errorContainer
        : scheme.surfaceContainerLow;
    final fg = filled ? scheme.onPrimary : scheme.onSurface;
    final sub = filled
        ? scheme.onPrimary.withValues(alpha: 0.85)
        : scheme.onSurfaceVariant;
    final side = filled
        ? BorderSide.none
        : BorderSide(
            color: danger
                ? scheme.error.withValues(alpha: 0.55)
                : scheme.outline,
          );

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        side: side,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 22, color: danger ? scheme.error : fg),
                const SizedBox(width: Vb.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          height: 20 / 15,
                          fontWeight: FontWeight.w600,
                          color: danger ? scheme.error : fg,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            if (emphasis != null)
                              TextSpan(
                                text: emphasis,
                                style: TextStyle(
                                  color: emphasisColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            TextSpan(text: detail),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          height: 16 / 12,
                          color: sub,
                        ),
                      ),
                    ],
                  ),
                ),
                if (badge != null)
                  Container(
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.onPrimary,
                      borderRadius: BorderRadius.circular(Vb.radiusPill),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
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

class _OverwriteDialog extends StatelessWidget {
  const _OverwriteDialog({required this.server});
  final SharedState server;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = _time(server.updatedAt);
    final preview = server.content
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(2);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: Vb.space6),
      child: Padding(
        padding: const EdgeInsets.all(Vb.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VbIconCircle(
              icon: LucideIcons.triangleAlert,
              color: scheme.error,
              background: scheme.errorContainer,
            ),
            const SizedBox(height: Vb.space4),
            Text(
              'Overwrite the server copy?',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: Vb.space2),
            Text(
              'The version saved${t != null ? ' at $t' : ''} (v${server.version}) will be replaced by your copy. VaultBridge can’t bring it back.',
              style: theme.textTheme.bodyLarge!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: Vb.space4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(Vb.radiusMd),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You’ll lose from the server copy:',
                      style: theme.textTheme.bodySmall!.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    for (final l in preview)
                      Text(
                        l,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.reading.code.copyWith(
                          fontSize: 12.5,
                          color: scheme.onSurface,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: Vb.space4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Vb.space2,
              runSpacing: Vb.space2,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.surface,
                    minimumSize: const Size(64, 44),
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                      fontFamily: Vb.sans,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Overwrite server'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
