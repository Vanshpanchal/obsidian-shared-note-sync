import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'asset_cache.dart';
import 'asset_info.dart';
import 'assets_api.dart';

/// Downloads attachments for the image cache, and refuses any response whose length
/// differs from the size the server declared (`x-asset-size`).
///
/// Without this, a body cut off by a proxy or function limit would be stored as if it were
/// the file, and the picture would stay broken until the cache was cleared.
class VerifiedFileService extends FileService {
  VerifiedFileService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final res = await _client.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 200) {
      final declared = int.tryParse(res.headers['x-asset-size'] ?? '');
      if (declared != null && declared != res.bodyBytes.length) {
        throw AssetTruncatedException(res.bodyBytes.length, declared);
      }
    }
    return BufferedFileResponse(
      statusCode: res.statusCode,
      bytes: res.bodyBytes,
      fileExtension: _extensionFor(
        Uri.parse(url).queryParameters['name'],
        res.headers,
      ),
    );
  }

  static String _extensionFor(String? name, Map<String, String> headers) {
    final fromName = extensionOf(name ?? '');
    if (fromName.isNotEmpty) return '.$fromName';
    final type = headers['content-type'] ?? '';
    const known = {
      'image/png': '.png',
      'image/jpeg': '.jpg',
      'image/gif': '.gif',
      'image/webp': '.webp',
      'application/pdf': '.pdf',
    };
    return known[type.split(';').first.trim()] ?? '';
  }
}

/// A fully buffered download, in the shape the cache manager expects.
class BufferedFileResponse implements FileServiceResponse {
  BufferedFileResponse({
    required this.statusCode,
    required this.bytes,
    required this.fileExtension,
  });

  final Uint8List bytes;

  @override
  final int statusCode;

  @override
  final String fileExtension;

  @override
  Stream<List<int>> get content => Stream.value(bytes);

  @override
  int? get contentLength => bytes.length;

  // A file's cache key already changes whenever the file does, so a stored copy never goes stale.
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 365));

  @override
  String? get eTag => null;
}

/// The one image/file cache for attachments, shared by `cached_network_image` (thumbnails,
/// pictures in notes) and the file viewer (so a picture is only downloaded once).
class AssetCacheManager extends CacheManager {
  AssetCacheManager._()
    : super(
        Config(
          folder,
          stalePeriod: const Duration(days: 90),
          maxNrOfCacheObjects: 400,
          fileService: VerifiedFileService(),
        ),
      );

  static const folder = 'vb_assets';
  static final AssetCacheManager instance = AssetCacheManager._();
}

/// [AssetCache] backed by [AssetCacheManager].
class ManagedAssetCache implements AssetCache {
  ManagedAssetCache([CacheManager? manager])
    : _manager = manager ?? AssetCacheManager.instance;

  final CacheManager _manager;

  // The URL is only an identifier here: the key decides what is stored where.
  String _url(AssetInfo i) => 'vbasset://${Uri.encodeComponent(i.name)}';

  @override
  Future<Uint8List?> read(AssetInfo info) async {
    try {
      final hit = await _manager.getFileFromCache(info.cacheKey);
      return hit == null ? null : await hit.file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(AssetInfo info, Uint8List bytes) async {
    try {
      final ext = extensionOf(info.name);
      await _manager.putFile(
        _url(info),
        bytes,
        key: info.cacheKey,
        maxAge: const Duration(days: 365),
        fileExtension: ext.isEmpty ? 'bin' : ext,
      );
    } catch (_) {
      // A full or read-only cache must never break viewing the file.
    }
  }

  @override
  Future<File?> file(AssetInfo info) async {
    try {
      return (await _manager.getFileFromCache(info.cacheKey))?.file;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(AssetInfo info) async {
    try {
      await _manager.removeFile(info.cacheKey);
    } catch (_) {}
  }

  @override
  Future<int> sizeBytes() async {
    try {
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/${AssetCacheManager.folder}',
      );
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File && !e.path.endsWith('.json') && !e.path.endsWith('.db')) {
          total += await e.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _manager.emptyCache();
    } catch (_) {}
  }
}
