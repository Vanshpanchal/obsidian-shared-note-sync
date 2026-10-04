import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/settings_store.dart';
import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../data/shared_repository.dart';
import '../theme/vb_theme.dart';
import 'onboarding_screen.dart';
import 'widgets.dart';

/// Pops `true` when the connection changed (so the caller re-syncs).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.repo,
    required this.assets,
  });

  final SettingsStore settings;
  final SharedRepository repo;
  final AssetsRepository assets;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _deviceName = TextEditingController(
    text: widget.settings.deviceName,
  );
  bool _changed = false;
  int _cacheEpoch = 0;

  SettingsStore get s => widget.settings;

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _editConnection() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(settings: s, dismissible: true),
      ),
    );
    if (saved == true) setState(() => _changed = true);
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Disconnect this device?'),
        content: const Text(
          'The endpoint and API key are removed from this phone. Your note stays in the vault.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await s.disconnect();
    if (mounted) Navigator.pop(context, true);
  }

  String get _synced {
    final d = widget.repo.updatedAt == null
        ? null
        : DateTime.tryParse(widget.repo.updatedAt!)?.toLocal();
    if (d == null || widget.repo.version == 0) return 'Not synced yet';
    final t =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return 'Last synced $t · v${widget.repo.version}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vb = context.vb;
    final key = s.apiKey;
    final masked = key.length > 4
        ? '••••••••${key.substring(key.length - 4)}'
        : '••••••••';

    Widget section(String title, Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: Vb.space2),
          child: Text(
            title,
            style: theme.textTheme.labelLarge!.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ),
        child,
      ],
    );

    Widget navRow(IconData icon, String title, Widget sub) => InkWell(
      onTap: _editConnection,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: Vb.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    sub,
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );

    final subStyle = theme.textTheme.bodySmall!.copyWith(height: 18 / 12);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            icon: Icon(LucideIcons.arrowLeft, color: scheme.onSurface),
            onPressed: () => Navigator.pop(context, _changed),
          ),
          title: const Text('Settings'),
        ),
        body: ListenableBuilder(
          listenable: s,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(Vb.space4),
            children: [
              section(
                'Connection',
                VbGroup(
                  children: [
                    navRow(
                      LucideIcons.globe,
                      'Endpoint',
                      Text(
                        s.endpoint.isEmpty ? 'Not set' : s.endpoint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.reading.code.copyWith(
                          fontSize: 12,
                          height: 18 / 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    navRow(
                      LucideIcons.keyRound,
                      'API key',
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            masked,
                            style: context.reading.code.copyWith(
                              fontSize: 12,
                              height: 18 / 12,
                              letterSpacing: 1,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Text(' · ', style: subStyle),
                          Icon(
                            LucideIcons.lock,
                            size: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text('In Keychain', style: subStyle),
                        ],
                      ),
                    ),
                    ListenableBuilder(
                      listenable: widget.repo,
                      builder: (context, _) {
                        final connected =
                            s.isConfigured &&
                            widget.repo.status != SyncStatus.error &&
                            widget.repo.status != SyncStatus.offline;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 40),
                            child: Row(
                              children: [
                                Icon(
                                  connected
                                      ? LucideIcons.circleCheck
                                      : LucideIcons.circleAlert,
                                  size: 20,
                                  color: connected ? vb.success : vb.warning,
                                ),
                                const SizedBox(width: Vb.space3),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        connected
                                            ? 'Connected'
                                            : 'Not connected',
                                        style: theme.textTheme.bodyLarge,
                                      ),
                                      Text(_synced, style: subStyle),
                                    ],
                                  ),
                                ),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(64, 40),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                    shape: const StadiumBorder(),
                                    textStyle: const TextStyle(
                                      fontFamily: Vb.sans,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  onPressed: () async {
                                    await widget.repo.pull();
                                  },
                                  child: const Text('Test'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Vb.space5),

              section(
                'Files',
                ListenableBuilder(
                  listenable: widget.assets,
                  builder: (context, _) => VbGroup(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.hardDrive,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: Vb.space3),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'On the server',
                                      style: theme.textTheme.bodyLarge,
                                    ),
                                    Text(
                                      widget.assets.loaded
                                          ? '${widget.assets.files.length} file'
                                                '${widget.assets.files.length == 1 ? '' : 's'}'
                                                ' · ${formatBytes(widget.assets.totalBytes)}'
                                          : 'Not loaded yet',
                                      style: subStyle,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      FutureBuilder<int>(
                        key: ValueKey(widget.assets.files.length + _cacheEpoch),
                        future: widget.assets.cache.sizeBytes(),
                        builder: (context, snap) => ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.download,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: Vb.space3),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Saved on this device',
                                        style: theme.textTheme.bodyLarge,
                                      ),
                                      Text(
                                        snap.hasData
                                            ? formatBytes(snap.data!)
                                            : '…',
                                        style: subStyle,
                                      ),
                                    ],
                                  ),
                                ),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(64, 40),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                    shape: const StadiumBorder(),
                                    textStyle: const TextStyle(
                                      fontFamily: Vb.sans,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  onPressed: () async {
                                    await widget.assets.cache.clear();
                                    if (mounted) setState(() => _cacheEpoch++);
                                  },
                                  child: const Text('Clear'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Vb.space5),
              section(
                'Appearance',
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(Vb.radiusMd),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Theme', style: theme.textTheme.bodyLarge),
                      const SizedBox(height: Vb.space2),
                      VbSegmented<ThemeMode>(
                        semanticLabel: 'Theme',
                        value: s.themeMode,
                        onChanged: s.setThemeMode,
                        options: const [
                          VbSegment(ThemeMode.system, 'System'),
                          VbSegment(ThemeMode.light, 'Light'),
                          VbSegment(ThemeMode.dark, 'Dark'),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text('Editor font', style: theme.textTheme.bodyLarge),
                      const SizedBox(height: Vb.space2),
                      VbSegmented<bool>(
                        semanticLabel: 'Editor font',
                        value: s.monoEditor,
                        onChanged: s.setMonoEditor,
                        options: [
                          const VbSegment(false, 'Sans'),
                          VbSegment(
                            true,
                            'Mono',
                            style: TextStyle(fontFamily: Vb.mono),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Vb.space5),
              section(
                'About',
                VbGroup(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Version', style: theme.textTheme.bodyLarge),
                            Text(
                              '0.1.0',
                              style: theme.textTheme.bodyMedium!.copyWith(
                                fontSize: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Device ID', style: theme.textTheme.bodyLarge),
                            const SizedBox(width: Vb.space4),
                            Flexible(
                              child: Text(
                                s.deviceId,
                                overflow: TextOverflow.ellipsis,
                                style: context.reading.code.copyWith(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Vb.space5),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                  minimumSize: const Size.fromHeight(Vb.touch),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Vb.radiusMd),
                  ),
                  textStyle: const TextStyle(
                    fontFamily: Vb.sans,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: _disconnect,
                child: const Text('Disconnect this device'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
