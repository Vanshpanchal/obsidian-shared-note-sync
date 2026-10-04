import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings_store.dart';
import 'shared_api.dart';

enum SyncStatus {
  notConfigured,
  saved,
  pending,
  saving,
  offline,
  conflict,
  error,
}

enum ConflictChoice { keepMine, useServer, saveMineAsCopy }

class ConflictCopy {
  const ConflictCopy(this.savedAt, this.content);
  final DateTime savedAt;
  final String content;
}

/// Local cache + sync logic. All network work runs through [_serial], so a pull
/// and a save never overlap and never race on [_lastVersion].
class SharedRepository extends ChangeNotifier {
  SharedRepository(
    this._prefs,
    this._settings, {
    SharedApi Function(String endpoint, String apiKey)? apiFactory,
    Stream<List<ConnectivityResult>>? connectivity,
    this.debounce = const Duration(seconds: 2),
    this.retryInterval = const Duration(seconds: 30),
  }) : _apiFactory =
           apiFactory ?? ((e, k) => SharedApi(endpoint: e, apiKey: k)),
       _connectivity = connectivity ?? Connectivity().onConnectivityChanged;

  final SharedPreferences _prefs;
  final SettingsStore _settings;
  final SharedApi Function(String, String) _apiFactory;
  final Stream<List<ConnectivityResult>> _connectivity;
  final Duration debounce;
  final Duration retryInterval;

  static const _kContent = 'repo.content';
  static const _kVersion = 'repo.version';
  static const _kDirty = 'repo.dirty';
  static const _kUpdatedAt = 'repo.updatedAt';
  static const _kCopies = 'repo.conflictCopies';

  SharedApi? _api;
  String _content = '';
  int _lastVersion = 0;
  bool _dirty = false;
  String? _updatedAt;
  SyncStatus _status = SyncStatus.saved;
  String? _errorMessage;
  SharedState? _conflict;

  Timer? _debounceTimer;
  Timer? _persistTimer;
  Timer? _retryTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Future<void> _queue = Future.value();

  String get content => _content;
  int get version => _lastVersion;
  bool get dirty => _dirty;
  String? get updatedAt => _updatedAt;
  SyncStatus get status => _status;
  String? get errorMessage => _errorMessage;
  SharedState? get conflict => _conflict;

  /// When the next automatic retry fires (offline / transient error), else null.
  DateTime? get nextRetryAt => _nextRetryAt;
  DateTime? _nextRetryAt;

  Future<void> init() async {
    _content = _prefs.getString(_kContent) ?? '';
    _lastVersion = _prefs.getInt(_kVersion) ?? 0;
    _dirty = _prefs.getBool(_kDirty) ?? false;
    _updatedAt = _prefs.getString(_kUpdatedAt);
    _status = _dirty ? SyncStatus.pending : SyncStatus.saved;
    _rebuildApi();
    notifyListeners();

    _connSub = _connectivity.listen((results) {
      if (!results.contains(ConnectivityResult.none) &&
          (_status == SyncStatus.offline || _status == SyncStatus.error)) {
        unawaited(pull());
      }
    });
    await pull();
  }

  /// Call after settings change.
  Future<void> reconfigure() async {
    _rebuildApi();
    await pull();
  }

  void _rebuildApi() {
    _api?.close();
    _api = _settings.isConfigured
        ? _apiFactory(_settings.endpoint, _settings.apiKey)
        : null;
    if (_api == null) _setStatus(SyncStatus.notConfigured);
  }

  /// Called on every keystroke.
  void edit(String text) {
    if (text == _content) return;
    _content = text;
    _dirty = true;
    _schedulePersist();
    if (_status != SyncStatus.conflict && _status != SyncStatus.notConfigured) {
      _setStatus(SyncStatus.pending);
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(save()));
    notifyListeners();
  }

  /// Save immediately (manual Save button, app pause).
  Future<void> flush() async {
    _debounceTimer?.cancel();
    await _persist();
    await save();
  }

  /// Fetches server state. Adopts it if newer and we have no local edits;
  /// pushes local edits if the server hasn't moved; flags a conflict otherwise.
  Future<void> pull() => _serial(() async {
    final api = _api;
    if (api == null) return _setStatus(SyncStatus.notConfigured);
    if (_status == SyncStatus.conflict) return; // wait for the user

    final SharedState server;
    try {
      server = await api.get();
    } catch (e) {
      return _handleError(e);
    }

    if (server.version != _lastVersion) {
      if (_dirty) {
        _conflict = server;
        _setStatus(SyncStatus.conflict);
      } else {
        await _adopt(server);
        _setStatus(SyncStatus.saved);
      }
    } else if (_dirty) {
      await _push(api);
    } else {
      _setStatus(SyncStatus.saved);
    }
  });

  Future<void> save({bool force = false}) => _serial(() async {
    final api = _api;
    if (api == null) return _setStatus(SyncStatus.notConfigured);
    if (!force && _status == SyncStatus.conflict) return; // wait for the user
    if (!_dirty && !force) {
      if (_status != SyncStatus.saved) _setStatus(SyncStatus.saved);
      return;
    }
    await _push(api, force: force);
  });

  Future<void> _push(SharedApi api, {bool force = false}) async {
    final snapshot = normalizeLineEndings(_content);
    _setStatus(SyncStatus.saving);
    try {
      final result = await api.save(
        content: snapshot,
        baseVersion: _lastVersion,
        deviceId: _settings.deviceId,
        force: force,
      );
      switch (result) {
        case SaveOk(:final version, :final updatedAt):
          _lastVersion = version;
          _updatedAt = updatedAt;
          _conflict = null;
          _retryTimer?.cancel();
          _nextRetryAt = null;
          // Edits made while the request was in flight stay dirty.
          _dirty = normalizeLineEndings(_content) != snapshot;
          await _persist();
          if (_dirty) {
            _setStatus(SyncStatus.pending);
            _debounceTimer?.cancel();
            _debounceTimer = Timer(debounce, () => unawaited(save()));
          } else {
            _setStatus(SyncStatus.saved);
          }
        case SaveConflict(:final server):
          _conflict = server;
          _setStatus(SyncStatus.conflict);
      }
    } catch (e) {
      await _persist(); // make sure the unsent edit is on disk
      _handleError(e);
    }
  }

  Future<void> resolveConflict(ConflictChoice choice) async {
    final server = _conflict;
    if (server == null) return;
    switch (choice) {
      case ConflictChoice.keepMine:
        _conflict = null;
        _dirty = true;
        _setStatus(SyncStatus.pending);
        await save(force: true);
      case ConflictChoice.saveMineAsCopy:
        await _addConflictCopy(_content);
        await _resolveWithServer(server);
      case ConflictChoice.useServer:
        await _resolveWithServer(server);
    }
  }

  Future<void> _resolveWithServer(SharedState server) async {
    _conflict = null;
    _dirty = false;
    await _adopt(server);
    _setStatus(SyncStatus.saved);
    await pull(); // in case the server moved again meanwhile
  }

  Future<void> _adopt(SharedState server) async {
    _content = server.content;
    _lastVersion = server.version;
    _updatedAt = server.updatedAt;
    await _persist();
    notifyListeners();
  }

  void _handleError(Object e) {
    if (e is OfflineException) {
      _errorMessage = null;
      _setStatus(SyncStatus.offline);
      _scheduleRetry();
    } else if (e is ApiException) {
      _errorMessage = e.message;
      _setStatus(SyncStatus.error);
      if (e.statusCode >= 500 || e.statusCode == 429) _scheduleRetry();
    } else {
      _errorMessage = e.toString();
      _setStatus(SyncStatus.error);
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    _nextRetryAt = DateTime.now().add(retryInterval);
    _retryTimer = Timer(retryInterval, () {
      _nextRetryAt = null;
      unawaited(pull());
    });
  }

  // ---- conflict copies ("Save mine as copy") ----

  List<ConflictCopy> get conflictCopies {
    final raw = _prefs.getStringList(_kCopies) ?? const [];
    return raw
        .map((s) {
          final j = jsonDecode(s) as Map<String, dynamic>;
          return ConflictCopy(
            DateTime.parse(j['savedAt'] as String),
            j['content'] as String,
          );
        })
        .toList()
        .reversed
        .toList();
  }

  Future<void> _addConflictCopy(String content) async {
    final list = _prefs.getStringList(_kCopies) ?? <String>[];
    list.add(
      jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'content': content,
      }),
    );
    await _prefs.setStringList(_kCopies, list);
  }

  Future<void> deleteConflictCopy(ConflictCopy copy) async {
    final list = _prefs.getStringList(_kCopies) ?? <String>[];
    final at = copy.savedAt.toIso8601String();
    final i = list.indexWhere(
      (s) => (jsonDecode(s) as Map<String, dynamic>)['savedAt'] == at,
    );
    if (i >= 0) list.removeAt(i);
    await _prefs.setStringList(_kCopies, list);
    notifyListeners();
  }

  Future<void> clearConflictCopies() async {
    await _prefs.remove(_kCopies);
    notifyListeners();
  }

  // ---- persistence ----

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_persist()),
    );
  }

  Future<void> _persist() async {
    _persistTimer?.cancel();
    await Future.wait([
      _prefs.setString(_kContent, _content),
      _prefs.setInt(_kVersion, _lastVersion),
      _prefs.setBool(_kDirty, _dirty),
      if (_updatedAt != null) _prefs.setString(_kUpdatedAt, _updatedAt!),
    ]);
  }

  void _setStatus(SyncStatus s) {
    _status = s;
    if (s != SyncStatus.error) _errorMessage = null;
    notifyListeners();
  }

  Future<void> _serial(Future<void> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.catchError((_) {});
    return next;
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _persistTimer?.cancel();
    _retryTimer?.cancel();
    _connSub?.cancel();
    _api?.close();
    super.dispose();
  }
}
