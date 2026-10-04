import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/assets_repository.dart';
import 'package:vault_bridge/data/shared_api.dart';
import 'package:vault_bridge/data/shared_repository.dart';
import 'package:vault_bridge/theme/vb_theme.dart';
import 'package:vault_bridge/ui/conflict_copies_screen.dart';
import 'package:vault_bridge/ui/conflict_screen.dart';
import 'package:vault_bridge/ui/onboarding_screen.dart';
import 'package:vault_bridge/ui/settings_screen.dart';
import 'package:vault_bridge/ui/shared_screen.dart';
import 'package:vault_bridge/ui/widgets.dart';
import 'helpers/fake_assets.dart';

class _Api extends SharedApi {
  _Api({this.offline = false}) : super(endpoint: 'https://x', apiKey: 'k');
  final bool offline;

  @override
  Future<SharedState> get() async {
    if (offline) throw const OfflineException(SocketException('down'));
    return const SharedState(content: '# Hi\n\n- [ ] one\n', version: 3);
  }

  @override
  void close() {}
}

class _MemSecure extends FlutterSecureStorage {
  _MemSecure(this.values);
  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    iOptions,
    aOptions,
    lOptions,
    webOptions,
    mOptions,
    wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    iOptions,
    aOptions,
    lOptions,
    webOptions,
    mOptions,
    wOptions,
  }) async {
    values[key] = value ?? '';
  }

  @override
  Future<void> delete({
    required String key,
    iOptions,
    aOptions,
    lOptions,
    webOptions,
    mOptions,
    wOptions,
  }) async {
    values.remove(key);
  }
}

void main() {
  Future<(SharedRepository, SettingsStore, AssetsRepository)> make({
    FakeAssetsServer? assetsServer,
    bool configured = true,
    bool offline = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (configured) 'settings.endpoint': 'https://sync.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(
      prefs,
      secure: _MemSecure({if (configured) 'settings.apiKey': 'vbk_live_3f9a'}),
    );
    await settings.load();
    final repo = SharedRepository(
      prefs,
      settings,
      apiFactory: (_, _) => _Api(offline: offline),
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
      retryInterval: const Duration(hours: 1),
    );
    final assets = await makeAssets(prefs, settings, assetsServer ?? FakeAssetsServer());
    return (repo, settings, assets);
  }

  Future<void> pump(WidgetTester tester, Widget home, Brightness b) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildVbTheme(b), home: home));
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final b in Brightness.values) {
    group(b.name, () {
      testWidgets('edit, preview, status sheet, settings, copies', (tester) async {
        final (repo, settings, assets) = await make();
        await repo.init();
        await pump(tester, SharedScreen(repo: repo, settings: settings, assets: assets), b);
        expect(tester.takeException(), isNull);
        expect(find.text('shared.md'), findsOneWidget);
        expect(find.bySemanticsLabel('Save now'), findsOneWidget); // FAB while keyboard is down

        await tester.tap(find.text('Preview'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('End of shared.md'), findsOneWidget);

        await tester.tap(find.byType(StatusChip));
        await tester.pumpAndSettle();
        expect(find.text('All saved'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.text('All saved'), findsNothing);

        await pump(tester, SettingsScreen(settings: settings, repo: repo, assets: assets), b);
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Disconnect this device'), findsOneWidget);
        await pump(tester, ConflictCopiesScreen(repo: repo), b);
        expect(find.text('No conflict copies'), findsOneWidget);
        expect(tester.takeException(), isNull);
        repo.dispose();
      });

      testWidgets('onboarding and conflict screens', (tester) async {
        final (repo, settings, _) = await make(configured: false);
        await pump(tester, OnboardingScreen(settings: settings), b);
        expect(find.text('Test connection'), findsOneWidget);

        await pump(
          tester,
          const ConflictScreen(
            server: SharedState(
              content: '- [x] a\nB',
              version: 19,
              updatedAt: '2026-10-04T10:48:00Z',
            ),
            mine: '- [ ] a\nC',
            baseVersion: 18,
          ),
          b,
        );
        expect(find.text('Save mine as copy'), findsOneWidget);
        await tester.tap(find.text('Keep mine'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Overwrite the server copy?'), findsOneWidget);
        expect(tester.takeException(), isNull);
        repo.dispose();
      });

      testWidgets('offline banner and first-load skeleton', (tester) async {
        final (repo, settings, assets) = await make(offline: true);
        await repo.init();
        await pump(tester, SharedScreen(repo: repo, settings: settings, assets: assets), b);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('You’re offline'), findsOneWidget);
        expect(tester.takeException(), isNull);
        repo.dispose();
      });
    });
  }
}
