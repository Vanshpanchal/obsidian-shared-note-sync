import 'dart:io';

import 'package:flutter/foundation.dart';

import 'asset_info.dart';

/// Where downloaded attachment bytes are kept so images show offline and aren't
/// fetched twice. Keyed by [AssetInfo.cacheKey], so a replaced file is a new entry.
abstract class AssetCache {
  Future<Uint8List?> read(AssetInfo info);
  Future<void> write(AssetInfo info, Uint8List bytes);

  /// A real file for sharing or opening elsewhere (null on platforms without one).
  Future<File?> file(AssetInfo info);
  Future<void> remove(AssetInfo info);
  Future<int> sizeBytes();
  Future<void> clear();
}

/// In-memory cache for tests and platforms without a temp directory.
class MemoryAssetCache implements AssetCache {
  final _bytes = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(AssetInfo info) async => _bytes[info.cacheKey];

  @override
  Future<void> write(AssetInfo info, Uint8List bytes) async =>
      _bytes[info.cacheKey] = bytes;

  @override
  Future<File?> file(AssetInfo info) async => null;

  @override
  Future<void> remove(AssetInfo info) async => _bytes.remove(info.cacheKey);

  @override
  Future<int> sizeBytes() async =>
      _bytes.values.fold<int>(0, (s, b) => s + b.length);

  @override
  Future<void> clear() async => _bytes.clear();
}
