import 'dart:typed_data';

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
import 'package:vault_bridge/ui/asset_viewer_screen.dart';
import 'package:vault_bridge/ui/asset_widgets.dart';
import 'package:vault_bridge/ui/attach_flow.dart';
import 'package:vault_bridge/ui/files_screen.dart';
import 'package:vault_bridge/ui/shared_screen.dart';
import 'package:vault_bridge/ui/widgets.dart';

import 'helpers/fake_assets.dart';

class _NoteApi extends SharedApi {
  _NoteApi(this.content) : super(endpoint: 'https://x', apiKey: 'k');
  final String content;

  @override
  Future<SharedState> get() async => SharedState(content: content, version: 3);

  @override
  void close() {}
}

void main() {
  late FakeAssetsServer server;
  late SharedPreferences prefs;
  late SettingsStore settings;
  late AssetsRepository assets;

  Future<SharedRepository> note(String content) async {
    final repo = SharedRepository(
      prefs,
      settings,
      apiFactory: (_, _) => _NoteApi(content),
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
      retryInterval: const Duration(hours: 1),
    );
    await repo.init();
    return repo;
  }

  setUp(() async {
    server = FakeAssetsServer(
      files: {'pic.png': tinyPng, 'Lease.pdf': Uint8List.fromList(List.filled(2048, 1))},
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings.apiKey': 'k'});
    prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings.endpoint', 'https://x');
    settings = SettingsStore(prefs);
    await settings.load();
    assets = await makeAssets(prefs, settings, server);
  });

  Future<void> pump(WidgetTester tester, Widget home, {Brightness b = Brightness.dark}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildVbTheme(b), home: home));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Files lists every file with size, and the footer totals', (tester) async {
    await assets.refresh();
    await pump(tester, FilesScreen(assets: assets));
    expect(find.text('pic.png'), findsOneWidget);
    expect(find.text('Lease.pdf'), findsOneWidget);
    expect(find.textContaining('2 KB'), findsWidgets);
    expect(find.textContaining('2 files'), findsOneWidget);
    expect(find.text('Add file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Files empty state explains what the folder is for', (tester) async {
    server.files.clear();
    await assets.refresh();
    await pump(tester, FilesScreen(assets: assets));
    expect(find.text('No files yet'), findsOneWidget);
    expect(find.textContaining('Shared/assets'), findsOneWidget);
  });

  testWidgets('Files shows the offline banner but keeps the cached list', (tester) async {
    await assets.refresh();
    server.online = false;
    await assets.refresh();
    await pump(tester, FilesScreen(assets: assets));
    expect(find.textContaining('You’re offline'), findsOneWidget);
    expect(find.text('pic.png'), findsOneWidget);
  });

  testWidgets('delete asks first, then removes the file everywhere', (tester) async {
    await assets.refresh();
    await pump(tester, FilesScreen(assets: assets));
    await tester.tap(find.byTooltip('Actions for Lease.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Lease.pdf?'), findsOneWidget);
    // Cancel keeps it.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.files.containsKey('Lease.pdf'), isTrue);

    await tester.tap(find.byTooltip('Actions for Lease.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(server.files.containsKey('Lease.pdf'), isFalse);
    expect(find.text('Lease.pdf'), findsNothing);
  });

  testWidgets('viewer shows an image, and a card with Share for other files', (tester) async {
    await assets.refresh();
    await pump(tester, AssetViewerScreen(assets: assets, info: assets.find('pic.png')!));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Image), findsWidgets);

    await pump(tester, AssetViewerScreen(assets: assets, info: assets.find('Lease.pdf')!));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Share or open in…'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
  });

  testWidgets('preview turns ![[pic.png]] into the picture and [[Lease.pdf]] into a file chip', (
    tester,
  ) async {
    await assets.refresh();
    final repo = await note('# Hi\n\n![[pic.png]]\n\n[[Lease.pdf]] and ![[missing.png]]\n');
    await pump(tester, SharedScreen(repo: repo, settings: settings, assets: assets));
    await tester.tap(find.text('Preview'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AssetImageEmbed), findsOneWidget);
    // An embed with no matching file keeps the plain chip.
    expect(find.textContaining('missing.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
    repo.dispose();
  });

  testWidgets('a wikilink to an attachment opens it in the app', (tester) async {
    await assets.refresh();
    final repo = await note('See [[Lease.pdf]] please.\n');
    await pump(tester, SharedScreen(repo: repo, settings: settings, assets: assets));
    await tester.tap(find.text('Preview'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapOnText(find.textRange.ofSubstring('Lease.pdf'));
    await tester.pumpAndSettle();
    expect(find.byType(AssetViewerScreen), findsOneWidget);
    repo.dispose();
  });

  testWidgets('a failed upload shows in the tray and Retry finishes it', (tester) async {
    server.online = false;
    await assets.upload(suggestedName: 'new.png', bytes: tinyPng);
    await pump(tester, Scaffold(body: UploadTray(repo: assets)));
    expect(find.textContaining('Couldn’t upload new.png'), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);

    server.online = true;
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(server.files.containsKey('new.png'), isTrue);
    expect(find.textContaining('Couldn’t upload'), findsNothing);
  });

  testWidgets('the attach sheet offers photos, files and already-uploaded files', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAttachSheet(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Photo library'), findsOneWidget);
    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Already uploaded'), findsOneWidget);
  });

  testWidgets('"Insert link in note" from Files puts the link at the cursor', (tester) async {
    await assets.refresh();
    final repo = await note('first line\n');
    await pump(tester, SharedScreen(repo: repo, settings: settings, assets: assets));
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions for pic.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert link in note'));
    await tester.pumpAndSettle();
    expect(repo.content, contains('![[pic.png]]'));
    expect(repo.content, startsWith('first line'));
    repo.dispose();
  });

  testWidgets('an empty note fits in a short window (keyboard open) without overflow', (
    tester,
  ) async {
    final repo = await note('');
    for (final height in [844.0, 330.0, 280.0, 220.0]) {
      tester.view.physicalSize = Size(390, height);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.dark),
          home: SharedScreen(repo: repo, settings: settings, assets: assets),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'overflow at height $height');
      expect(find.text('Nothing here yet.'), findsOneWidget);
    }
    addTearDown(tester.view.reset);
    repo.dispose();
  });

  group('landscape / short windows', () {
    void shortWindow(WidgetTester tester, {double height = 240, double keyboard = 0}) {
      tester.view.physicalSize = Size(640, height);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
    }

    testWidgets('the attach sheet scrolls instead of overflowing', (tester) async {
      shortWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showAttachSheet(context),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Photo library'), findsOneWidget);
      // The last option is reachable by scrolling.
      await tester.dragUntilVisible(
        find.text('Already uploaded'),
        find.byType(SingleChildScrollView).last,
        const Offset(0, -60),
      );
      expect(find.text('Already uploaded'), findsOneWidget);
    });

    testWidgets('the sync status sheet scrolls instead of overflowing', (tester) async {
      shortWindow(tester);
      await assets.refresh();
      final repo = await note('hello');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.dark),
          home: SharedScreen(repo: repo, settings: settings, assets: assets),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(StatusChip));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('All saved'), findsOneWidget);
      repo.dispose();
    });

    testWidgets('Edit/Preview tabs step aside only with the keyboard up in a short window', (
      tester,
    ) async {
      final repo = await note('hello');
      Future<void> show() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildVbTheme(Brightness.dark),
            home: SharedScreen(repo: repo, settings: settings, assets: assets),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }

      shortWindow(tester, height: 390);
      await show();
      expect(find.text('Preview'), findsOneWidget, reason: 'keyboard down: tabs visible');

      shortWindow(tester, height: 390, keyboard: 200);
      await show();
      expect(find.text('Preview'), findsNothing, reason: 'keyboard up in a short window');

      tester.view.physicalSize = const Size(390, 844);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await show();
      expect(find.text('Preview'), findsOneWidget, reason: 'tall window keeps the tabs');
      expect(tester.takeException(), isNull);
      repo.dispose();
    });
  });
}
