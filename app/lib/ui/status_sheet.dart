import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/settings_store.dart';
import '../data/shared_repository.dart';
import '../theme/vb_theme.dart';
import 'widgets.dart';

/// Bottom sheet opened from the status chip: what's waiting, when it retries,
/// and a primary action.
Future<void> showStatusSheet(
  BuildContext context, {
  required SharedRepository repo,
  required SettingsStore settings,
  required VoidCallback onRetry,
  VoidCallback? onOpenSettings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _StatusSheet(
      repo: repo,
      settings: settings,
      onRetry: onRetry,
      onOpenSettings: onOpenSettings,
    ),
  );
}

class _StatusSheet extends StatefulWidget {
  const _StatusSheet({
    required this.repo,
    required this.settings,
    required this.onRetry,
    this.onOpenSettings,
  });

  final SharedRepository repo;
  final SettingsStore settings;
  final VoidCallback onRetry;
  final VoidCallback? onOpenSettings;

  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  Timer? _tick;

  SharedRepository get repo => widget.repo;
  SettingsStore get settings => widget.settings;
  VoidCallback get onRetry => widget.onRetry;

  @override
  void initState() {
    super.initState();
    // Re-render once a second so the retry countdown is live.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    repo.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    repo.removeListener(_changed);
    super.dispose();
  }

  String get _countdown {
    final at = repo.nextRetryAt;
    if (at == null) return 'Retrying soon';
    final s = at.difference(DateTime.now()).inSeconds;
    if (s <= 0) return 'Retrying now…';
    return s >= 90
        ? 'Retrying in ${(s / 60).round()} min'
        : 'Retrying in ${s}s';
  }

  String _last() {
    final d = repo.updatedAt == null
        ? null
        : DateTime.tryParse(repo.updatedAt!)?.toLocal();
    final t = d == null
        ? null
        : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (repo.version == 0) return 'Never';
    return t == null
        ? 'version ${repo.version}'
        : '$t · version ${repo.version}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;

    final (
      String title,
      String sub,
      IconData icon,
      Color fg,
      Color bg,
      String? action,
      Color? nextTry,
    ) = switch (repo.status) {
      SyncStatus.offline => (
        'Offline – will retry',
        'Your latest edit is safe on this phone.',
        LucideIcons.cloudOff,
        vb.warning,
        vb.warningContainer,
        'Retry now',
        vb.warning,
      ),
      SyncStatus.error => (
        'Sync error',
        repo.errorMessage ?? 'The last sync didn’t go through.',
        LucideIcons.circleAlert,
        scheme.error,
        scheme.errorContainer,
        'Try again',
        scheme.error,
      ),
      SyncStatus.pending => (
        'Unsaved changes',
        'Saves on its own a moment after you stop typing.',
        LucideIcons.pencilLine,
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHigh,
        'Save now',
        null,
      ),
      SyncStatus.saving => (
        'Saving…',
        'Uploading your latest edit.',
        LucideIcons.cloudUpload,
        vb.info,
        vb.infoContainer,
        null,
        null,
      ),
      SyncStatus.conflict => (
        'Conflict',
        'Resolve it to continue syncing.',
        LucideIcons.triangleAlert,
        scheme.error,
        scheme.errorContainer,
        'Resolve',
        null,
      ),
      SyncStatus.notConfigured => (
        'Not connected',
        'Add your endpoint and API key to start syncing.',
        LucideIcons.settings,
        scheme.primary,
        scheme.primaryContainer,
        'Set up',
        null,
      ),
      SyncStatus.saved => (
        'All saved',
        'This phone matches your vault.',
        LucideIcons.cloudCheck,
        vb.success,
        vb.successContainer,
        'Sync now',
        null,
      ),
    };

    Widget row(String k, String v, {Color? vColor}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k,
            style: theme.textTheme.bodyLarge!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Vb.space3),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyLarge!.copyWith(
                fontWeight: FontWeight.w500,
                color: vColor,
              ),
            ),
          ),
        ],
      ),
    );

    final device = settings.deviceName.isEmpty
        ? 'This phone'
        : settings.deviceName;

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Vb.radiusXl),
        ),
        boxShadow: [
          BoxShadow(
            color: vb.shadowSheet,
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Vb.space6,
          Vb.space2,
          Vb.space6,
          Vb.space8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(bottom: Vb.space5),
                decoration: BoxDecoration(
                  color: scheme.outline,
                  borderRadius: BorderRadius.circular(Vb.radiusPill),
                ),
              ),
            ),
            Row(
              children: [
                VbIconCircle(icon: icon, color: fg, background: bg),
                const SizedBox(width: Vb.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: theme.textTheme.bodySmall!.copyWith(
                          fontSize: 13,
                          height: 18 / 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Vb.space5),
            VbGroup(
              color: scheme.surfaceContainerLow,
              children: [
                if (repo.dirty) row('Waiting to upload', '1 change'),
                if (nextTry != null &&
                    (repo.status == SyncStatus.offline ||
                        repo.status == SyncStatus.error) &&
                    repo.nextRetryAt != null)
                  row('Next try', _countdown, vColor: nextTry),
                row('Last synced', _last()),
                row('This device', device),
              ],
            ),
            const SizedBox(height: Vb.space5),
            if (action != null)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  onRetry();
                },
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                label: Text(action),
              ),
            if (repo.status == SyncStatus.error &&
                widget.onOpenSettings != null) ...[
              const SizedBox(height: Vb.space2),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onOpenSettings!();
                },
                child: const Text('Open Settings'),
              ),
            ],
            const SizedBox(height: Vb.space2),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                minimumSize: const Size.fromHeight(Vb.touch),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Vb.radiusMd),
                ),
                textStyle: const TextStyle(
                  fontFamily: Vb.sans,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
