import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/asset_cache.dart';
import 'package:vault_bridge/data/asset_cache_manager.dart';
import 'package:vault_bridge/data/asset_info.dart';
import 'package:vault_bridge/data/assets_api.dart';
import 'package:vault_bridge/data/assets_repository.dart';
import 'package:vault_bridge/data/shared_api.dart';

AssetInfo info(String name, {int size = 4, String updated = 't1'}) =>
    AssetInfo(name: name, size: size, mimeType: 'x/y', updatedAt: updated);

void main() {
  group('AssetNames', () {
    test('sanitize replaces characters that break wikilinks or paths', () {
      expect(AssetNames.sanitize('a/b#c^d[e]f|g.png'), 'a-b-c-d-e-f-g.png');
      expect(AssetNames.sanitize('  .hidden. '), 'hidden');
      expect(AssetNames.sanitize(''), 'File');
      expect(AssetNames.sanitize('IMG   1.png'), 'IMG 1.png');
      expect(AssetNames.sanitize('${'x' * 300}.png').length, 200);
      expect(AssetNames.sanitize('${'x' * 300}.png').endsWith('.png'), isTrue);
    });

    test('unique appends (2), (3) case-insensitively and keeps the extension', () {
      expect(AssetNames.unique('a.png', []), 'a.png');
      expect(AssetNames.unique('a.png', ['A.PNG']), 'a (2).png');
      expect(AssetNames.unique('a.png', ['a.png', 'a (2).png']), 'a (3).png');
      expect(AssetNames.unique('noext', ['noext']), 'noext (2)');
    });

    test('fromTarget strips headings, block ids and folders', () {
      expect(AssetNames.fromTarget('Shared/assets/pic.png'), 'pic.png');
      expect(AssetNames.fromTarget('doc.pdf#page=3'), 'doc.pdf');
      expect(AssetNames.fromTarget('  note.png '), 'note.png');
      expect(AssetNames.fromTarget('#heading'), '');
    });

    test('stamped names are sortable', () {
      expect(
        AssetNames.stamped('Photo', 'jpg', DateTime(2026, 10, 4, 9, 5, 7)),
        'Photo 20261004-090507.jpg',
      );
    });
  });

  group('AssetInfo', () {
    test('kind and link depend on the extension', () {
      expect(info('a.PNG').isImage, isTrue);
      expect(info('a.png').link, '![[a.png]]');
      expect(info('Lease.pdf').kind, AssetKind.pdf);
      expect(info('Lease.pdf').link, '[[Lease.pdf]]');
      expect(info('x.unknown').kind, AssetKind.other);
    });

    test('formatBytes', () {
      expect(formatBytes(64), '64 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(2 * 1024 * 1024 + 400 * 1024), '2.4 MB');
      expect(formatBytes(25 * 1024 * 1024), '25 MB');
    });

    test('list round-trips through json', () {
      final list = [info('a.png'), info('b.pdf', size: 9)];
      final back = AssetInfo.decodeList(AssetInfo.encodeList(list));
      expect(back.map((f) => f.name), ['a.png', 'b.pdf']);
      expect(back.last.size, 9);
      expect(AssetInfo.decodeList('not json'), isEmpty);
    });
  });

  group('AssetsApi', () {
    AssetsApi api(MockClientHandler handler) =>
        AssetsApi(endpoint: 'https://x', apiKey: 'k', client: MockClient(handler));

    test('list parses files and the server size limit', () async {
      final a = api((req) async {
        expect(req.url.path, '/assets');
        expect(req.headers['x-api-key'], 'k');
        return http.Response(
          jsonEncode({
            'files': [
              {'name': 'a.png', 'size': 3, 'mimeType': 'image/png', 'updatedAt': 't'},
            ],
            'maxBytes': 1000,
          }),
          200,
        );
      });
      final list = await a.list();
      expect(list.files.single.name, 'a.png');
      expect(list.maxBytes, 1000);
    });

    test('upload sends raw bytes with the name in the query', () async {
      final a = api((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/assets/file');
        expect(req.url.queryParameters['name'], 'my photo.png');
        expect(req.url.queryParameters.containsKey('overwrite'), isFalse);
        expect(req.bodyBytes, [1, 2, 3]);
        return http.Response(
          jsonEncode({'name': 'my photo.png', 'size': 3, 'mimeType': 'image/png'}),
          201,
        );
      });
      final saved = await a.upload('my photo.png', Uint8List.fromList([1, 2, 3]));
      expect(saved.name, 'my photo.png');
    });

    test('upload maps 409 and 413', () async {
      final exists = api((_) async => http.Response(jsonEncode({'error': 'exists'}), 409));
      await expectLater(exists.upload('a.png', Uint8List(1)), throwsA(isA<AssetExistsException>()));
      final big = api(
        (_) async => http.Response(jsonEncode({'error': 'payload_too_large', 'maxBytes': 77}), 413),
      );
      await expectLater(
        big.upload('a.png', Uint8List(1)),
        throwsA(isA<AssetTooLargeException>().having((e) => e.maxBytes, 'maxBytes', 77)),
      );
    });

    test('download returns the bytes when the length matches', () async {
      final a = api(
        (_) async => http.Response.bytes([1, 2, 3, 4], 200, headers: {'x-asset-size': '4'}),
      );
      expect(await a.download(info('a.png')), [1, 2, 3, 4]);
    });

    test('download refuses a body shorter than the file', () async {
      final a = api((_) async => http.Response.bytes([1, 2], 200, headers: {'x-asset-size': '4'}));
      await expectLater(a.download(info('a.png')), throwsA(isA<AssetTruncatedException>()));
    });

    test('delete treats 404 as already deleted; other errors throw', () async {
      await api((_) async => http.Response('{}', 404)).delete('a.png');
      await expectLater(
        api(
          (_) async => http.Response(jsonEncode({'error': 'internal_error'}), 500),
        ).delete('a.png'),
        throwsA(isA<ApiException>()),
      );
    });

    test('errors: 401 and 501 get friendly messages; no network is an OfflineException', () async {
      await expectLater(
        api((_) async => http.Response('{}', 401)).list(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid API key')),
      );
      await expectLater(
        api((_) async => http.Response('{}', 501)).list(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('not set up'))),
      );
      await expectLater(
        api((_) async => throw const SocketException('down')).list(),
        throwsA(isA<OfflineException>()),
      );
    });
  });

  group('VerifiedFileService (image cache downloads)', () {
    VerifiedFileService service(MockClientHandler h) => VerifiedFileService(client: MockClient(h));

    test('returns the bytes when the length matches what the server declared', () async {
      final svc = service((req) async {
        expect(req.headers['x-api-key'], 'k');
        return http.Response.bytes([1, 2, 3, 4], 200, headers: {'x-asset-size': '4'});
      });
      final res = await svc.get('https://x/assets/file?name=pic.png', headers: {'x-api-key': 'k'});
      expect(res.statusCode, 200);
      expect(res.contentLength, 4);
      expect(await res.content.expand((c) => c).toList(), [1, 2, 3, 4]);
      expect(res.fileExtension, '.png');
    });

    test('a body shorter than declared is rejected, so it is never cached', () async {
      final svc = service(
        (_) async => http.Response.bytes([1, 2], 200, headers: {'x-asset-size': '4'}),
      );
      await expectLater(
        svc.get('https://x/assets/file?name=pic.png'),
        throwsA(isA<AssetTruncatedException>().having((e) => e.expected, 'expected', 4)),
      );
    });

    test('errors pass through with their status; a missing size header is tolerated', () async {
      final notFound = await service(
        (_) async => http.Response('{}', 404),
      ).get('https://x/a?name=a.png');
      expect(notFound.statusCode, 404);
      final noHeader = await service(
        (_) async => http.Response.bytes([1], 200),
      ).get('https://x/a?name=b.pdf');
      expect(noHeader.statusCode, 200);
      expect(noHeader.fileExtension, '.pdf');
    });

    test('stored copies stay valid for a long time (the key changes with the file)', () async {
      final res = await service(
        (_) async => http.Response.bytes([1], 200),
      ).get('https://x/a?name=a.png');
      expect(res.validTill.isAfter(DateTime.now().add(const Duration(days: 300))), isTrue);
    });
  });

  group('AssetsRepository', () {
    late _FakeServer server;
    late AssetsRepository repo;
    late MemoryAssetCache cache;

    setUp(() async {
      server = _FakeServer();
      SharedPreferences.setMockInitialValues({'settings.endpoint': 'https://x'});
      FlutterSecureStorage.setMockInitialValues({'settings.apiKey': 'k'});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsStore(prefs);
      await settings.load();
      cache = MemoryAssetCache();
      repo = AssetsRepository(
        prefs,
        settings,
        apiFactory: (_, _) => _FakeApi(server),
        cache: cache,
      );
    });

    Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

    test('upload stores the file, caches its bytes and lists it', () async {
      final saved = await repo.upload(suggestedName: 'photo.png', bytes: bytes(5));
      expect(saved!.name, 'photo.png');
      expect(repo.files.map((f) => f.name), ['photo.png']);
      expect(repo.uploads, isEmpty);
      expect(await cache.read(saved), hasLength(5));
      expect(server.files.keys, ['photo.png']);
    });

    test('a taken or invalid name is made unique and safe', () async {
      await repo.upload(suggestedName: 'photo.png', bytes: bytes(5));
      final second = await repo.upload(suggestedName: 'Photo.PNG', bytes: bytes(5));
      expect(second!.name, 'Photo (2).PNG');
      final odd = await repo.upload(suggestedName: 'a/b#c.png', bytes: bytes(5));
      expect(odd!.name, 'a-b-c.png');
    });

    test('losing the connection keeps the task so Retry can finish it', () async {
      server.online = false;
      final failed = await repo.upload(suggestedName: 'a.png', bytes: bytes(5));
      expect(failed, isNull);
      final task = repo.uploads.single;
      expect(task.state, UploadState.failed);
      expect(task.offline, isTrue);
      server.online = true;
      final saved = await repo.retry(task);
      expect(saved!.name, 'a.png');
      expect(repo.uploads, isEmpty);
    });

    test('over the size limit fails before any request', () async {
      await repo.refresh(); // learns maxBytes = 10
      final r = await repo.upload(suggestedName: 'big.bin', bytes: bytes(11));
      expect(r, isNull);
      expect(repo.uploads.single.error, contains('too large'));
      expect(server.files, isEmpty);
    });

    test('a name taken on another device since the last listing gets a free name', () async {
      server.files['a.png'] = bytes(3); // repo doesn't know yet
      final saved = await repo.upload(suggestedName: 'a.png', bytes: bytes(5));
      expect(saved!.name, 'a (2).png');
      expect(server.files.keys.toSet(), {'a.png', 'a (2).png'});
    });

    test('find resolves wikilink targets', () async {
      await repo.upload(suggestedName: 'Plan.pdf', bytes: bytes(5));
      expect(repo.find('plan.pdf')!.name, 'Plan.pdf');
      expect(repo.find('Shared/assets/Plan.pdf#page=2')!.name, 'Plan.pdf');
      expect(repo.find('Other note'), isNull);
    });

    test('bytes come from the cache first, and are cached after a download', () async {
      server.files['x.png'] = bytes(4);
      await repo.refresh();
      final f = repo.find('x.png')!;
      expect(await repo.bytes(f), hasLength(4));
      expect(server.downloads, 1);
      expect(await repo.bytes(f), hasLength(4));
      expect(server.downloads, 1, reason: 'second read must hit the cache');
    });

    test('delete removes the file everywhere', () async {
      final saved = await repo.upload(suggestedName: 'a.png', bytes: bytes(5));
      await repo.delete(saved!);
      expect(repo.files, isEmpty);
      expect(server.files, isEmpty);
      expect(await cache.read(saved), isNull);
    });

    test('offline refresh keeps the cached listing', () async {
      await repo.upload(suggestedName: 'a.png', bytes: bytes(5));
      server.online = false;
      await repo.refresh();
      expect(repo.offline, isTrue);
      expect(repo.files, hasLength(1));
    });
  });
}

/// In-memory server behind [_FakeApi].
class _FakeServer {
  final files = <String, Uint8List>{};
  bool online = true;
  int downloads = 0;
  int clock = 0;
  final updated = <String, String>{};
}

class _FakeApi extends AssetsApi {
  _FakeApi(this.s)
    : super(
        endpoint: 'https://x',
        apiKey: 'k',
        client: MockClient((_) async => http.Response('', 500)),
      );
  final _FakeServer s;

  AssetInfo _info(String name) => AssetInfo(
    name: name,
    size: s.files[name]!.length,
    mimeType: 'x/y',
    updatedAt: s.updated[name] ?? 't0',
  );

  void _check() {
    if (!s.online) throw const OfflineException(SocketException('down'));
  }

  @override
  Future<AssetList> list() async {
    _check();
    return AssetList([for (final n in s.files.keys) _info(n)], 10);
  }

  @override
  Future<AssetInfo> upload(String name, Uint8List bytes, {bool overwrite = false}) async {
    _check();
    final clash = s.files.keys.any((n) => n.toLowerCase() == name.toLowerCase());
    if (clash && !overwrite) throw AssetExistsException(name);
    s.files[name] = bytes;
    s.updated[name] = 't${++s.clock}';
    return _info(name);
  }

  @override
  Future<Uint8List> download(AssetInfo info) async {
    _check();
    s.downloads++;
    return s.files[info.name]!;
  }

  @override
  Future<void> delete(String name) async {
    _check();
    s.files.remove(name);
  }

  @override
  void close() {}
}
