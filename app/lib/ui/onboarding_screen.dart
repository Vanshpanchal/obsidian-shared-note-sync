import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/settings_store.dart';
import '../data/shared_api.dart';
import '../theme/vb_theme.dart';
import 'widgets.dart';

enum _Test { idle, testing, success, wrongKey, unreachable }

/// First-run connection screen. Pops `true` once the connection is saved.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.settings,
    this.dismissible = false,
  });

  final SettingsStore settings;

  /// Opened from Settings (edit the connection) rather than first run: show a close button.
  final bool dismissible;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final _endpoint = TextEditingController(text: widget.settings.endpoint);
  late final _apiKey = TextEditingController(text: widget.settings.apiKey);
  final _form = GlobalKey<FormState>();
  bool _obscure = true;
  _Test _test = _Test.idle;
  String _detail = '';

  @override
  void dispose() {
    _endpoint.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  String? _validateUrl(String? v) {
    final uri = Uri.tryParse(v?.trim() ?? '');
    if (uri == null || !uri.isAbsolute || uri.scheme != 'https')
      return 'Enter an https:// URL';
    return null;
  }

  String _base(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/shared'))
      url = url.substring(0, url.length - '/shared'.length);
    return url;
  }

  Future<void> _runTest() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _test = _Test.testing);
    final api = SharedApi(
      endpoint: _base(_endpoint.text),
      apiKey: _apiKey.text.trim(),
    );
    try {
      final s = await api.get();
      if (!mounted) return;
      final kb = (s.content.length / 1024).toStringAsFixed(1);
      setState(() {
        _test = _Test.success;
        _detail = 'Found shared.md · version ${s.version} · $kb KB';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _test = e.statusCode == 401 || e.statusCode == 403
            ? _Test.wrongKey
            : _Test.unreachable;
        _detail = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _test = _Test.unreachable);
    } finally {
      api.close();
    }
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    await widget.settings.save(endpoint: _endpoint.text, apiKey: _apiKey.text);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = context.reading.code.copyWith(fontSize: 14, height: 1.2);

    return Scaffold(
      appBar: widget.dismissible
          ? AppBar(
              leading: IconButton(
                tooltip: 'Close',
                icon: Icon(LucideIcons.x, color: scheme.onSurface),
                onPressed: () => Navigator.pop(context),
              ),
              title: const Text('Connection'),
            )
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Vb.space6,
              Vb.space10,
              Vb.space6,
              Vb.space8,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: c.maxHeight - Vb.space10 - Vb.space8,
              ),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: const Center(child: VbMark(size: 30)),
                        ),
                        const SizedBox(width: Vb.space3),
                        Text('VaultBridge', style: theme.textTheme.titleLarge),
                      ],
                    ),
                    const SizedBox(height: Vb.space5),
                    Text(
                      'One note. Your vault and your phone, always in step.',
                      style: theme.textTheme.titleLarge!.copyWith(
                        fontSize: 28,
                        height: 36 / 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Connect to the endpoint that serves Shared/shared.md from your vault.',
                      style: theme.textTheme.bodyLarge!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Vb.space8),
                    _label(context, 'Endpoint URL'),
                    TextFormField(
                      controller: _endpoint,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: mono,
                      decoration: const InputDecoration(
                        hintText: 'https://xxxx.appwrite.run',
                      ),
                      validator: _validateUrl,
                      onChanged: (_) => setState(() => _test = _Test.idle),
                    ),
                    const SizedBox(height: Vb.space4),
                    _label(context, 'API key'),
                    TextFormField(
                      controller: _apiKey,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: mono.copyWith(letterSpacing: _obscure ? 2 : 0),
                      decoration: InputDecoration(
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Show API key' : 'Hide API key',
                          icon: Icon(
                            _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v?.trim().isEmpty ?? true) ? 'Required' : null,
                      onChanged: (_) => setState(() => _test = _Test.idle),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Stored in the system keychain on this device.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: Vb.space4),
                    _result(context),
                    const SizedBox(height: Vb.space8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _connect,
                      child: const Text('Connect'),
                    ),
                    const SizedBox(height: Vb.space2),
                    OutlinedButton(
                      onPressed: _test == _Test.testing ? null : _runTest,
                      child: _test == _Test.testing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Test connection'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge!.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _result(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final (String title, String body, IconData icon, Color fg, Color bg)?
    r = switch (_test) {
      _Test.success => (
        'Connection works',
        _detail,
        LucideIcons.circleCheck,
        vb.success,
        vb.successContainer,
      ),
      _Test.wrongKey => (
        'Wrong API key',
        'The server answered but didn’t accept this key. Check for a missing character.',
        LucideIcons.circleAlert,
        scheme.error,
        scheme.errorContainer,
      ),
      _Test.unreachable => (
        'Can’t reach the server',
        'Check the URL and your connection, then test again.',
        LucideIcons.cloudOff,
        vb.warning,
        vb.warningContainer,
      ),
      _ => null,
    };
    if (r == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: r.$5,
          borderRadius: BorderRadius.circular(Vb.radiusMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(r.$3, size: 20, color: r.$4),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.$1,
                    style: TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w600,
                      color: r.$4,
                    ),
                  ),
                  Text(
                    r.$2,
                    style: TextStyle(
                      fontSize: 13,
                      height: 18 / 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
