// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/asset_cache.dart';
import 'package:vault_bridge/data/asset_info.dart';
import 'package:vault_bridge/data/assets_repository.dart';
import 'package:vault_bridge/theme/vb_theme.dart';
import 'package:vault_bridge/ui/asset_widgets.dart';

import 'helpers/fake_assets.dart';

/// Stands in for AssetCacheManager: serves a local file and records what was asked for.
class _FakeCacheManager extends CacheManager {
  _FakeCacheManager(this.file)
    : super(
        Config('vb_test_images', repo: NonStoringObjectProvider(), fileService: HttpFileService()),
      );

  final File file;
  final requests = <({String url, String? key, Map<String, String>? headers})>[];
  Object? failWith;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requests.add((url: url, key: key, headers: headers));
    if (failWith != null) return Stream.error(failWith!);
    return Stream.value(
      FileInfo(
        const LocalFileSystem().file(file.path),
        FileSource.Online,
        DateTime.now().add(const Duration(days: 1)),
        url,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late File pngFile;
  late _FakeCacheManager manager;
  late AssetsRepository assets;
  final info = AssetInfo(
    name: 'IMG 0005.jpeg',
    size: 1484524,
    mimeType: 'image/jpeg',
    updatedAt: '2026-10-04T06:54:52.874+00:00',
  );

  setUp(() async {
    // Flutter's in-memory image cache is global; a picture loaded by an earlier test must not
    // satisfy this one.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    // The cache manager asks path_provider for its folders when it is created.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    pngFile = File(
      '${Directory.systemTemp.path}/vb_test_pic_${DateTime.now().microsecondsSinceEpoch}.png',
    )..writeAsBytesSync(tinyPng);
    manager = _FakeCacheManager(pngFile);
    SharedPreferences.setMockInitialValues({
      'settings.endpoint': 'https://vault.example.test',
    });
    FlutterSecureStorage.setMockInitialValues({'settings.apiKey': 'secret-key'});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(prefs);
    await settings.load();
    // No imageFactory: this is the real cached_network_image path.
    assets = AssetsRepository(
      prefs,
      settings,
      apiFactory: (e, k) => FakeAssetsApiAt(e, k),
      cache: MemoryAssetCache(),
      imageCacheManager: manager,
    );
  });

  tearDown(() {
    if (pngFile.existsSync()) pngFile.deleteSync();
  });

  Future<void> pumpEmbed(WidgetTester tester, {double? width}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AssetImageEmbed(info: info, repo: assets, width: width),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'a picture in a note loads through cached_network_image (no assertion, no error card)',
    (tester) async {
      await pumpEmbed(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Couldn’t load'), findsNothing);
      expect(manager.requests, isNotEmpty);
      final request = manager.requests.first;
      expect(request.url, 'https://vault.example.test/assets/file?name=IMG%200005.jpeg');
      expect(request.headers, containsPair('x-api-key', 'secret-key'));
      // The cache key carries the file's version, so a replaced picture is fetched again.
      expect(request.key, info.cacheKey);
    },
  );

  testWidgets('the same works with a width, as in ![[pic.png|240]]', (tester) async {
    await pumpEmbed(tester, width: 240);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Couldn’t load'), findsNothing);
  });

  testWidgets('thumbnails use the same path and never throw', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.light),
        home: Scaffold(
          body: AssetThumb(info: info, repo: assets),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull);
    expect(manager.requests, isNotEmpty);
  });

  testWidgets('a download failure shows the retry card, and Retry loads it again', (tester) async {
    manager.failWith = const HttpException('boom');
    await pumpEmbed(tester);
    expect(find.textContaining('Couldn’t load IMG 0005.jpeg'), findsOneWidget);

    manager.failWith = null;
    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.textContaining('Couldn’t load'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
