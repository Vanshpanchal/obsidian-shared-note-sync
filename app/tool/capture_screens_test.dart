// ignore_for_file: invalid_use_of_visible_for_testing_member, unused_local_variable
// Renders every screen at 390x844 (@2x) in light and dark with the bundled
// fonts, for side-by-side comparison with the design.
//
//   CAPTURE_DIR=/some/dir flutter test tool/capture_screens_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/shared_api.dart';
import 'package:vault_bridge/data/shared_repository.dart';
import 'package:vault_bridge/theme/vb_theme.dart';
import 'package:vault_bridge/ui/conflict_copies_screen.dart';
import 'package:vault_bridge/ui/conflict_screen.dart';
import 'package:vault_bridge/ui/onboarding_screen.dart';
import 'package:vault_bridge/ui/settings_screen.dart';
import 'package:vault_bridge/ui/shared_screen.dart';
import 'package:vault_bridge/data/assets_repository.dart';
import 'package:vault_bridge/markdown/mermaid_view.dart';
import 'package:vault_bridge/ui/asset_viewer_screen.dart';
import 'package:vault_bridge/ui/files_screen.dart';
import 'package:vault_bridge/ui/widgets.dart';
import '../test/helpers/fake_assets.dart';

const _note = r'''---
tags: [inbox, ideas, ideas/garden]
aliases: [Scratchpad, Phone inbox]
due: 2026-10-06
pinned: true
archived: false
related: ["[[Garden plan]]", "[[Q4 goals]]"]
---
# Weekly scratch

Call [[Ravi Menon|Ravi]] about the #ideas/garden plan[^1].

![[diagram.png]]

![[Garden photo.jpg|240]]

[[Lease.pdf]] is attached.

## Tasks

- [ ] Draft grant summary
- [x] Renew domain
- [/] Sort trip photos
- [-] Cancelled idea
- [>] Rescheduled
- [?] Ask the landlord
- [!] Pay rent by Friday

## Callouts

> [!note] Note
> This file syncs with `Shared/shared.md`. Edits on either side land here.

> [!tip] Tip
> Type `[[` to link a note. It opens in Obsidian.

> [!warning] Warning
> The lease renewal form is due Friday.

> [!danger] Danger
> Don’t paste passwords here.

> [!quote] Quote
> Write it down first. Tidy it later, at a desk.

> [!example]- Old drafts
> Three versions of the intro.

> [!question] Raised beds or pots?
> Leaning raised beds.
> > [!success] Decided
> > Two beds on the south side.

### Bed size

Soil per bed is $V = l \cdot w \cdot h$.

$$V = \sum_{i=1}^{2} l_i w_i h_i \approx \frac{1.73}{1} m^3$$

```dart
final res = await api.get('/note');
final v = res.json['version'];
// pull if the server moved on
if (v > local.version) {
  await pull();
}
```

```mermaid
graph LR
  Phone --> Server
```

## This week

| Day | Focus | Hours |
| --- | --- | ---: |
| Mon | Grant draft | 3 |
| Tue | [[Garden plan]] | 1.5 |

> Small notes, kept in one place, beat good notes scattered everywhere.

On macOS press <kbd>⌘</kbd> <kbd>S</kbd>. ==Highlighted text== here.

[^1]: pH 6.5, from the kit in the shed. Retest in spring.
''';

const _mermaidNote = r'''# Diagrams

```mermaid
graph TD
  A[Start] --> B{Works?}
  B -->|yes| C[Ship it]
  B -->|no| D[Fix it]
  D --> A
```

```mermaid
sequenceDiagram
  Phone->>Server: save (v18)
  Server-->>Phone: ok (v19)
  Server->>Vault: write shared.md
```

```mermaid
pie title Storage
  "Images" : 6
  "PDFs" : 3
  "Other" : 1
```

```mermaid
stateDiagram-v2
  [*] --> Saved
  Saved --> Unsaved: edit
  Unsaved --> Saved: sync
```

```mermaid
graph TD
  A -->
```
''';

class _Api extends SharedApi {
  _Api(this.mode, this.content) : super(endpoint: 'https://x', apiKey: 'k');
  final String mode; // ok | offline | wrongkey | hang
  final String content;

  @override
  Future<SharedState> get() async {
    switch (mode) {
      case 'offline':
        throw const OfflineException(SocketException('down'));
      case 'wrongkey':
        throw const ApiException(401, 'Invalid API key');
      case 'hang':
        return Completer<SharedState>().future;
    }
    return SharedState(content: content, version: 18, updatedAt: '2026-10-04T10:42:00Z');
  }

  @override
  void close() {}
}

class _Mem extends FlutterSecureStorage {
  _Mem(this.values);
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
  }) async => values[key] = value ?? '';
  @override
  Future<void> delete({
    required String key,
    iOptions,
    aOptions,
    lOptions,
    webOptions,
    mOptions,
    wOptions,
  }) async => values.remove(key);
}

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(File('assets/fonts/$f').readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await l.load();
  }

  await load('Inter', [
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'Inter-Bold.ttf',
    'Inter-Italic.ttf',
  ]);
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')
      ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
    await l.load();
  }
  final lucide = Directory(
    '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev',
  ).listSync().whereType<Directory>().where((d) => d.path.contains('lucide_icons_flutter-'));
  if (lucide.isNotEmpty) {
    final l = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(
        File(
          '${lucide.last.path}/assets/lucide.ttf',
        ).readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    await l.load();
  }
  await load('JetBrains Mono', ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Medium.ttf']);
}

void main() {
  final out = Directory(Platform.environment['CAPTURE_DIR'] ?? '/tmp/vb_shots')
    ..createSync(recursive: true);

  Uint8List? pngBytes;
  Future<Uint8List> gradient(int w, int h, Color a, Color b) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w.toDouble(), h.toDouble()), [a, b]),
    );
    c.drawCircle(Offset(w * .7, h * .35), h * .16, Paint()..color = const Color(0xFFFFF3C4));
    final image = await rec.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<Map<String, Uint8List>> files() async {
    pngBytes ??= await gradient(640, 400, const Color(0xFF5B8DEF), const Color(0xFF2E7D5B));
    return {
      'Garden photo.jpg': pngBytes!,
      'diagram.png': pngBytes!,
      'Lease.pdf': Uint8List(2516582),
      'Budget 2026.xlsx': Uint8List(184320),
      'Voice memo.m4a': Uint8List(912384),
    };
  }

  Future<(SharedRepository, SettingsStore, AssetsRepository)> make({
    FakeAssetsServer? assetsServer,
    bool noAssets = false,
    String mode = 'ok',
    String content = _note,
    bool configured = true,
    bool dirty = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (configured) 'settings.endpoint': 'https://sync.example.com/v1',
      if (configured) 'settings.deviceName': 'Pixel 8',
      if (dirty) 'repo.dirty': true,
      if (dirty) 'repo.content': content,
      if (dirty) 'repo.version': 18,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(
      prefs,
      secure: _Mem({if (configured) 'settings.apiKey': 'vbk_live_3f9a8c21d0'}),
    );
    await settings.load();
    final repo = SharedRepository(
      prefs,
      settings,
      apiFactory: (_, _) => _Api(mode, content),
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
      retryInterval: const Duration(seconds: 30),
    );
    final server = assetsServer ?? FakeAssetsServer(files: noAssets ? {} : await files());
    final assets = await makeAssets(prefs, settings, server);
    await assets.refresh();
    return (repo, settings, assets);
  }

  final key = GlobalKey();

  Future<void> shot(
    WidgetTester tester,
    String name,
    Brightness b,
    Widget home, {
    double height = 844,
  }) async {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox()); // drop any routes from the previous shot
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildVbTheme(b), home: home),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // Let async work (image decoding) finish, then draw it.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/${b.name}-$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  for (final b in Brightness.values) {
    testWidgets('capture ${b.name}', (tester) async {
      await tester.runAsync(() => files());
      // 1 onboarding
      var (repo, settings, assets) = await make(configured: false);
      await shot(tester, '1-onboarding', b, OnboardingScreen(settings: settings));

      // 2 edit (content), 3 preview
      (repo, settings, assets) = await make();
      await tester.runAsync(() => repo.init());
      await shot(tester, '2-edit', b, SharedScreen(repo: repo, settings: settings, assets: assets));
      await tester.tap(find.text('Preview'));
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${out.path}/${b.name}-3-preview-top.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      });
      // full-length preview
      await shot(
        tester,
        '3-preview-full',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
        height: 4200,
      );
      await tester.tap(find.text('Preview'));
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${out.path}/${b.name}-3-preview-full.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      });
      repo.dispose();

      // 4 status sheet (offline)
      (repo, settings, assets) = await make(mode: 'offline', dirty: true);
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '8b-offline',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
      );
      await tester.tap(find.byType(StatusChip));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${out.path}/${b.name}-4-status-sheet.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      });
      repo.dispose();

      // 5 conflict + confirm
      const server = SharedState(
        content: '- [x] Renew domain\n- [x] Draft grant summary\nBudget sent to Ravi.',
        version: 19,
        updatedAt: '2026-10-04T10:48:00Z',
      );
      await shot(
        tester,
        '5-conflict',
        b,
        const ConflictScreen(
          server: server,
          mine: '- [x] Renew domain\n- [ ] Draft grant summary\nGroceries: oat milk, limes, coffee',
          baseVersion: 18,
        ),
      );
      await tester.tap(find.text('Keep mine'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/${b.name}-5b-confirm.png').writeAsBytesSync(data!.buffer.asUint8List());
      });

      // 6 copies
      (repo, settings, assets) = await make();
      SharedPreferences.setMockInitialValues({});
      await shot(tester, '6-copies-empty', b, ConflictCopiesScreen(repo: repo));
      repo.dispose();

      // 7 settings
      (repo, settings, assets) = await make();
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '7-settings',
        b,
        SettingsScreen(settings: settings, repo: repo, assets: assets),
      );
      repo.dispose();

      Future<void> snap(String name) async {
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${out.path}/${b.name}-$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        });
      }

      // 9 files: list, empty, viewers, attach sheet, failed upload
      (repo, settings, assets) = await make();
      await shot(tester, '9-files', b, FilesScreen(assets: assets, onInsert: (_) {}));
      (repo, settings, assets) = await make(noAssets: true);
      await shot(tester, '9b-files-empty', b, FilesScreen(assets: assets, onInsert: (_) {}));
      (repo, settings, assets) = await make();
      await shot(
        tester,
        '9c-viewer-image',
        b,
        AssetViewerScreen(assets: assets, info: assets.find('Garden photo.jpg')!),
      );
      await shot(
        tester,
        '9d-viewer-file',
        b,
        AssetViewerScreen(assets: assets, info: assets.find('Lease.pdf')!),
      );

      final assetServer = FakeAssetsServer(files: await files());
      (repo, settings, assets) = await make(assetsServer: assetServer);
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '9e-edit-with-tray',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
      );
      assetServer.online = false;
      await assets.upload(suggestedName: 'Receipt.jpg', bytes: Uint8List(4096));
      await tester.pump(const Duration(milliseconds: 300));
      await snap('9e-edit-with-tray');
      await tester.tap(find.bySemanticsLabel('Attach file'));
      await tester.pumpAndSettle();
      await snap('9f-attach-sheet');
      repo.dispose();

      // 10 mermaid diagrams in the preview
      (repo, settings, assets) = await make(content: _mermaidNote);
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '10-mermaid',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
        height: 2300,
      );
      await tester.tap(find.text('Preview'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await snap('10-mermaid');
      repo.dispose();

      // 10b full-screen mermaid viewer with zoom controls
      await shot(
        tester,
        '10b-mermaid-viewer',
        b,
        Builder(
          builder: (context) {
            final r = MermaidResult.render(
              'graph TD\n  A[Start] --> B{Works?}\n  B -->|yes| C[Ship it]\n  B -->|no| D[Fix it]\n  D --> A',
              mermaidThemeFor(context),
            );
            return MermaidViewerScreen(renderer: r.renderer!);
          },
        ),
      );

      // 8a skeleton, 8c empty, 8d wrong key
      (repo, settings, assets) = await make(mode: 'hang', content: '');
      await shot(
        tester,
        '8a-skeleton',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
      );
      repo.dispose();
      (repo, settings, assets) = await make(content: '');
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '8c-empty',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
      );
      repo.dispose();
      (repo, settings, assets) = await make(mode: 'wrongkey', content: '');
      await tester.runAsync(() => repo.init());
      await shot(
        tester,
        '8d-wrongkey',
        b,
        SharedScreen(repo: repo, settings: settings, assets: assets),
      );
      repo.dispose();
    });
  }
}
