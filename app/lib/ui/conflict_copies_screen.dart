import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/shared_repository.dart';
import '../theme/vb_theme.dart';

/// Local copies kept by "Save mine as copy" in the conflict flow.
class ConflictCopiesScreen extends StatelessWidget {
  const ConflictCopiesScreen({super.key, required this.repo});

  final SharedRepository repo;

  static String _when(DateTime d) {
    final l = d.toLocal();
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
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    return '${l.day} ${m[l.month - 1]}, $t';
  }

  void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
        );

  Future<void> _read(BuildContext context, ConflictCopy c) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Vb.space6,
                Vb.space4,
                Vb.space2,
                Vb.space2,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _when(c.savedAt),
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: c.content));
                      Navigator.pop(ctx);
                      _toast(context, 'Copied to clipboard');
                    },
                  ),
                ],
              ),
            ),
            Divider(color: scheme.outlineVariant),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(Vb.space4),
                child: SelectableText(c.content, style: context.reading.code),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final copies = repo.conflictCopies;
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Back',
              icon: Icon(LucideIcons.arrowLeft, color: scheme.onSurface),
              onPressed: () => Navigator.maybePop(context),
            ),
            title: const Text('Conflict copies'),
            actions: [
              if (copies.isNotEmpty) ...[
                Center(
                  child: Text(
                    '${copies.length} ${copies.length == 1 ? 'copy' : 'copies'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Delete all',
                  icon: const Icon(LucideIcons.trash2),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Delete all conflict copies?'),
                        content: const Text(
                          'They only exist on this phone and can’t be recovered.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: scheme.error,
                            ),
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await repo.clearConflictCopies();
                  },
                ),
                const SizedBox(width: Vb.space2),
              ],
            ],
          ),
          body: copies.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Vb.space10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.copy,
                          size: 32,
                          color: context.vb.inkFaint,
                        ),
                        const SizedBox(height: Vb.space3),
                        Text(
                          'No conflict copies',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Copies appear here when you choose “Save mine as copy”.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Vb.space4,
                        Vb.space4,
                        Vb.space4,
                        Vb.space2,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Kept on this phone when you chose “Save mine as copy”. Tap to read, swipe left to delete.',
                          style: theme.textTheme.bodySmall!.copyWith(
                            fontSize: 13,
                            height: 18 / 13,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: copies.length,
                        itemBuilder: (context, i) {
                          final c = copies[i];
                          final firstLine = c.content
                              .split('\n')
                              .firstWhere(
                                (l) => l.trim().isNotEmpty,
                                orElse: () => '(empty)',
                              );
                          return Dismissible(
                            key: ValueKey(c.savedAt.toIso8601String()),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: scheme.error,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: Vb.space5),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    LucideIcons.trash2,
                                    size: 18,
                                    color: scheme.surface,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Delete',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.surface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            onDismissed: (_) => repo.deleteConflictCopy(c),
                            child: Container(
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerLow,
                                border: Border(
                                  bottom: BorderSide(
                                    color: scheme.outlineVariant,
                                  ),
                                ),
                              ),
                              child: InkWell(
                                onTap: () => _read(context, c),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    4,
                                    12,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _when(c.savedAt),
                                              style: theme.textTheme.bodyLarge!
                                                  .copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              firstLine,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: context.reading.code
                                                  .copyWith(
                                                    fontSize: 13,
                                                    height: 20 / 13,
                                                    color:
                                                        scheme.onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Copy text',
                                        icon: const Icon(LucideIcons.copy),
                                        onPressed: () {
                                          Clipboard.setData(
                                            ClipboardData(text: c.content),
                                          );
                                          _toast(
                                            context,
                                            'Copied to clipboard',
                                          );
                                        },
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Vb.space4,
                        Vb.space2,
                        Vb.space4,
                        Vb.space8,
                      ),
                      child: Text(
                        'Copies never sync. Paste one into the note to bring text back.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
