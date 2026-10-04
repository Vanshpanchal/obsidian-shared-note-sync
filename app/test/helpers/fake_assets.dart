import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/asset_cache.dart';
import 'package:vault_bridge/data/asset_info.dart';
import 'package:vault_bridge/data/assets_api.dart';
import 'package:vault_bridge/data/assets_repository.dart';
import 'package:vault_bridge/data/shared_api.dart';

/// A valid 1x1 PNG, so `Image.memory` has something real to decode.
final tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// In-memory attachments server.
class FakeAssetsServer {
  FakeAssetsServer({Map<String, Uint8List>? files}) : files = files ?? {};
  final Map<String, Uint8List> files;
  bool online = true;
  int maxBytes = 10 * 1024 * 1024;
  int clock = 0;
  final updated = <String, String>{};
}

class FakeAssetsApi extends AssetsApi {
  FakeAssetsApi(this.s)
    : super(
        endpoint: 'https://x',
        apiKey: 'k',
        client: MockClient((_) async => http.Response('', 500)),
      );
  final FakeAssetsServer s;

  AssetInfo _info(String name) => AssetInfo(
    name: name,
    size: s.files[name]!.length,
    mimeType: 'x/y',
    createdAt: '2026-10-04T10:00:00Z',
    updatedAt: s.updated[name] ?? '2026-10-04T10:4${s.files.keys.toList().indexOf(name) % 10}:00Z',
  );

  void _check() {
    if (!s.online) throw const OfflineException(SocketException('down'));
  }

  @override
  Future<AssetList> list() async {
    _check();
    return AssetList([for (final n in s.files.keys) _info(n)], s.maxBytes);
  }

  @override
  Future<AssetInfo> upload(String name, Uint8List bytes, {bool overwrite = false}) async {
    _check();
    if (s.files.keys.any((n) => n.toLowerCase() == name.toLowerCase()) && !overwrite) {
      throw AssetExistsException(name);
    }
    s.files[name] = bytes;
    s.updated[name] = '2026-10-04T11:0${++s.clock}:00Z';
    return _info(name);
  }

  @override
  Future<Uint8List> download(AssetInfo info) async {
    _check();
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

Future<AssetsRepository> makeAssets(
  SharedPreferences prefs,
  SettingsStore settings,
  FakeAssetsServer server,
) async {
  final repo = AssetsRepository(
    prefs,
    settings,
    apiFactory: (_, _) => FakeAssetsApi(server),
    cache: MemoryAssetCache(),
    // Pictures come from the fake server instead of the network image cache.
    imageFactory: (info, {cacheWidth}) => MemoryImage(server.files[info.name] ?? tinyPng),
  );
  return repo;
}

/// An [AssetsApi] for the given endpoint and key that never touches the network, so
/// `fileUrl` and `authHeaders` are the real ones.
class FakeAssetsApiAt extends AssetsApi {
  FakeAssetsApiAt(String endpoint, String apiKey)
    : super(
        endpoint: endpoint,
        apiKey: apiKey,
        client: MockClient((_) async => http.Response('', 500)),
      );
}
