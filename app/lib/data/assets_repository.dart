import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings_store.dart';
import 'asset_cache.dart';
import 'asset_cache_manager.dart';
import 'asset_info.dart';
import 'assets_api.dart';
import 'shared_api.dart';

enum UploadState { uploading, failed }

/// One file on its way to the server. Failed tasks keep their bytes so Retry works.
/// How a picture is loaded. The default uses `cached_network_image`; tests swap it.
typedef AssetImageFactory =
    ImageProvider Function(AssetInfo info, {int? cacheWidth});

class UploadTask {
  UploadTask({required this.id, required this.name, required this.bytes});

  final int id;
  String name;
  final Uint8List bytes;
  UploadState state = UploadState.uploading;
  String? error;

  /// The failure was a lost connection (as opposed to the server refusing the file).
  bool offline = false;
}

/// The attachments (`Shared/assets` in the vault): the file list, uploads with retry,
/// downloads through a disk cache, and resolving `[[wikilinks]]` to files.
class AssetsRepository extends ChangeNotifier {
  AssetsRepository(
    this._prefs,
    this._settings, {
    AssetsApi Function(String endpoint, String apiKey)? apiFactory,
    AssetCache? cache,
    this.imageFactory,
    this.imageCacheManager,
  }) : _apiFactory =
           apiFactory ?? ((e, k) => AssetsApi(endpoint: e, apiKey: k)),
       cache = cache ?? ManagedAssetCache() {
    _files = AssetInfo.decodeList(_prefs.getString(_kList));
    _maxBytes = _prefs.getInt(_kMax) ?? 10 * 1024 * 1024;
  }

  final SharedPreferences _prefs;
  final SettingsStore _settings;
  final AssetsApi Function(String, String) _apiFactory;
  final AssetCache cache;

  /// Overrides how pictures load (tests); null uses `cached_network_image`.
  final AssetImageFactory? imageFactory;

  /// Null means AssetCacheManager.instance, which is only created when a picture is requested.
  final BaseCacheManager? imageCacheManager;

  static const _kList = 'assets.list';
  static const _kMax = 'assets.maxBytes';

  AssetsApi? _api;
  List<AssetInfo> _files = const [];
  int _maxBytes = 10 * 1024 * 1024;
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  bool _offline = false;
  final _uploads = <UploadTask>[];
  int _nextTaskId = 1;
  final _inflight = <String, Future<Uint8List>>{};

  /// Newest first.
  List<AssetInfo> get files => _files;
  int get maxBytes => _maxBytes;
  bool get loading => _loading;

  /// True once a listing (or a cached one) is available, so UIs can tell "empty" from "unknown".
  bool get loaded => _loaded || _files.isNotEmpty;
  String? get error => _error;
  bool get offline => _offline;
  List<UploadTask> get uploads => List.unmodifiable(_uploads);
  bool get configured => _settings.isConfigured;
  int get totalBytes => _files.fold(0, (s, f) => s + f.size);

  AssetsApi? get _client {
    if (!_settings.isConfigured) return null;
    return _api ??= _apiFactory(_settings.endpoint, _settings.apiKey);
  }

  /// Call after the endpoint or key changed.
  void reconfigure() {
    _api?.close();
    _api = null;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final api = _client;
    if (api == null || _loading) return;
    _loading = true;
    notifyListeners();
    try {
      final list = await api.list();
      _files = _sorted(list.files);
      _maxBytes = list.maxBytes;
      _loaded = true;
      _error = null;
      _offline = false;
      await _prefs.setString(_kList, AssetInfo.encodeList(_files));
      await _prefs.setInt(_kMax, _maxBytes);
    } on OfflineException {
      _offline = true;
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
      _offline = false;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  static List<AssetInfo> _sorted(List<AssetInfo> files) =>
      [...files]..sort((a, b) {
        final ta = a.modified, tb = b.modified;
        if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  // ------------------------------------------------------------ lookup

  /// The attachment a `[[target]]` / `![[target]]` points at, or null.
  AssetInfo? find(String target) {
    final name = AssetNames.fromTarget(target).toLowerCase();
    if (name.isEmpty) return null;
    for (final f in _files) {
      if (f.name.toLowerCase() == name) return f;
    }
    return null;
  }

  // ------------------------------------------------------------ upload

  /// Queues an upload. The file keeps [suggestedName] unless that is taken (or invalid),
  /// in which case it becomes `name (2).ext`. Resolves with the stored file, or null if the
  /// upload failed (the task stays in [uploads] for Retry).
  Future<AssetInfo?> upload({
    required String suggestedName,
    required Uint8List bytes,
  }) async {
    final name = AssetNames.unique(
      AssetNames.sanitize(suggestedName),
      _takenNames(),
    );
    final task = UploadTask(id: _nextTaskId++, name: name, bytes: bytes);
    _uploads.add(task);
    notifyListeners();
    return _run(task);
  }

  Future<AssetInfo?> retry(UploadTask task) {
    task
      ..state = UploadState.uploading
      ..error = null
      ..offline = false;
    notifyListeners();
    return _run(task);
  }

  void dismiss(UploadTask task) {
    _uploads.remove(task);
    notifyListeners();
  }

  Iterable<String> _takenNames() => [
    ..._files.map((f) => f.name),
    // Names of uploads still in flight are reserved too.
    ..._uploads
        .where((t) => t.state == UploadState.uploading)
        .map((t) => t.name),
  ];

  Future<AssetInfo?> _run(UploadTask task) async {
    final api = _client;
    if (api == null) {
      return _fail(
        task,
        'Set up the endpoint and API key first',
        offline: false,
      );
    }
    if (task.bytes.isEmpty)
      return _fail(task, 'The file is empty', offline: false);
    if (task.bytes.length > _maxBytes) {
      return _fail(
        task,
        AssetTooLargeException(_maxBytes).toString(),
        offline: false,
      );
    }
    try {
      AssetInfo saved;
      try {
        saved = await api.upload(task.name, task.bytes);
      } on AssetExistsException {
        // Another device added the same name since our last listing: take a free one.
        await refresh();
        task.name = AssetNames.unique(task.name, _files.map((f) => f.name));
        saved = await api.upload(task.name, task.bytes);
      }
      await cache.write(saved, task.bytes);
      _files = _sorted([
        ..._files.where(
          (f) => f.name.toLowerCase() != saved.name.toLowerCase(),
        ),
        saved,
      ]);
      await _prefs.setString(_kList, AssetInfo.encodeList(_files));
      _uploads.remove(task);
      _loaded = true;
      notifyListeners();
      return saved;
    } on OfflineException {
      return _fail(
        task,
        'No connection. Your file is kept; retry when you’re back online.',
        offline: true,
      );
    } on AssetTooLargeException catch (e) {
      if (e.maxBytes > 0) _maxBytes = e.maxBytes;
      return _fail(task, e.toString(), offline: false);
    } on ApiException catch (e) {
      return _fail(task, e.message, offline: false);
    } catch (e) {
      return _fail(task, e.toString(), offline: false);
    }
  }

  AssetInfo? _fail(UploadTask task, String message, {required bool offline}) {
    task
      ..state = UploadState.failed
      ..error = message
      ..offline = offline;
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------ pictures

  /// A cached, authenticated image provider for [info] (via `cached_network_image`).
  /// The cache key includes the file's version, so a replaced picture reloads, and the
  /// download is length-checked before it is stored (see [VerifiedFileService]).
  ImageProvider imageFor(AssetInfo info, {int? cacheWidth}) {
    final factory = imageFactory;
    if (factory != null) return factory(info, cacheWidth: cacheWidth);
    final api = _client;
    // Not set up: an empty image makes the widget show its error state instead of throwing.
    if (api == null) return MemoryImage(Uint8List(0));
    final provider = CachedNetworkImageProvider(
      api.fileUrl(info.name),
      headers: api.authHeaders,
      cacheKey: info.cacheKey,
      cacheManager: imageCacheManager ?? AssetCacheManager.instance,
    );
    // Downscale while decoding. (CachedNetworkImageProvider's own maxWidth is only allowed
    // with a resizing ImageCacheManager and asserts otherwise; the cache keeps the original.)
    return cacheWidth == null
        ? provider
        : ResizeImage(provider, width: cacheWidth);
  }

  /// Forget a picture that failed to load so the next attempt hits the network again.
  Future<void> evictImage(AssetInfo info) async {
    final provider = imageFor(info);
    await provider.evict();
    await cache.remove(info);
  }

  // ------------------------------------------------------------ download

  /// Bytes of a file: from the disk cache, else downloaded (and cached). Concurrent calls
  /// for the same file share one download.
  Future<Uint8List> bytes(AssetInfo info) {
    final key = info.cacheKey;
    return _inflight[key] ??= _load(info).whenComplete(() {
      // Block body on purpose: an arrow would return the removed future itself, which
      // whenComplete would then wait on forever.
      _inflight.remove(key);
    });
  }

  Future<Uint8List> _load(AssetInfo info) async {
    final cached = await cache.read(info);
    if (cached != null && cached.length == info.size) return cached;
    final api = _client;
    if (api == null)
      throw const ApiException(0, 'Set up the endpoint and API key first');
    final data = await api.download(info);
    await cache.write(info, data);
    return data;
  }

  /// A local file for the system share sheet. Downloads first if needed.
  Future<String?> localPath(AssetInfo info) async {
    await bytes(info);
    return (await cache.file(info))?.path;
  }

  // ------------------------------------------------------------ delete

  Future<void> delete(AssetInfo info) async {
    final api = _client;
    if (api == null)
      throw const ApiException(0, 'Set up the endpoint and API key first');
    await api.delete(info.name);
    await cache.remove(info);
    _files = [
      for (final f in _files)
        if (f.name != info.name) f,
    ];
    await _prefs.setString(_kList, AssetInfo.encodeList(_files));
    notifyListeners();
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }
}
