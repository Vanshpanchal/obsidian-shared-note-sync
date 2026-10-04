import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_bridge/config/settings_store.dart';
import 'package:vault_bridge/data/shared_api.dart';
import 'package:vault_bridge/data/shared_repository.dart';

/// In-memory server with the same version rules as the Appwrite function.
class FakeServer {
  String content = '';
  int version = 0;
  bool online = true;
  int saves = 0;
  Completer<void>? holdSave;
}

class FakeApi extends SharedApi {
  FakeApi(this.server) : super(endpoint: 'https://x', apiKey: 'k');
  final FakeServer server;

  @override
  Future<SharedState> get() async {
    if (!server.online) throw const OfflineException(SocketException('down'));
    return SharedState(content: server.content, version: server.version);
  }

  @override
  Future<SaveResult> save({
    required String content,
    required int baseVersion,
    required String deviceId,
    bool force = false,
  }) async {
    if (!server.online) throw const OfflineException(SocketException('down'));
    if (server.holdSave != null) await server.holdSave!.future;
    if (!force && baseVersion != server.version) {
      return SaveConflict(SharedState(content: server.content, version: server.version));
    }
    server.saves++;
    server.content = content;
    server.version++;
    return SaveOk(server.version, DateTime.now().toIso8601String());
  }

  @override
  void close() {}
}

void main() {
  late FakeServer server;
  late SharedPreferences prefs;
  late StreamController<List<ConnectivityResult>> conn;

  Future<SharedRepository> makeRepo() async {
    final settings = SettingsStore(prefs);
    await settings.load();
    final repo = SharedRepository(
      prefs,
      settings,
      apiFactory: (_, _) => FakeApi(server),
      connectivity: conn.stream,
      debounce: const Duration(milliseconds: 20),
      retryInterval: const Duration(hours: 1),
    );
    await repo.init();
    return repo;
  }

  setUp(() async {
    server = FakeServer();
    conn = StreamController.broadcast();
    SharedPreferences.setMockInitialValues({'settings.endpoint': 'https://x'});
    FlutterSecureStorage.setMockInitialValues({'settings.apiKey': 'k'});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 60));

  test('launch adopts newer server content when there are no local edits', () async {
    server
      ..content = 'from server'
      ..version = 3;
    final repo = await makeRepo();
    expect(repo.content, 'from server');
    expect(repo.version, 3);
    expect(repo.status, SyncStatus.saved);
  });

  test('edit is debounced, normalized and saved', () async {
    final repo = await makeRepo();
    repo.edit('a\r\nb');
    repo.edit('a\r\nbc');
    expect(repo.status, SyncStatus.pending);
    await settle();
    expect(server.saves, 1);
    expect(server.content, 'a\nbc');
    expect(repo.status, SyncStatus.saved);
    expect(repo.dirty, isFalse);
  });

  test('offline edit is kept and syncs on reconnect', () async {
    final repo = await makeRepo();
    server.online = false;
    repo.edit('offline edit');
    await settle();
    expect(repo.status, SyncStatus.offline);
    expect(prefs.getString('repo.content'), 'offline edit');
    expect(prefs.getBool('repo.dirty'), isTrue);

    server.online = true;
    conn.add([ConnectivityResult.wifi]);
    await settle();
    expect(server.content, 'offline edit');
    expect(repo.status, SyncStatus.saved);
  });

  test('dirty cache survives restart and is pushed on launch', () async {
    final first = await makeRepo();
    server.online = false;
    first.edit('unsent');
    await first.flush();
    first.dispose();

    server.online = true;
    final second = await makeRepo();
    expect(second.content, 'unsent');
    expect(server.content, 'unsent');
    expect(second.status, SyncStatus.saved);
  });

  test('server moved while dirty -> conflict, nothing overwritten', () async {
    final repo = await makeRepo();
    server
      ..content = 'other device'
      ..version = 1;
    repo.edit('mine');
    await settle();
    expect(repo.status, SyncStatus.conflict);
    expect(repo.conflict!.content, 'other device');
    expect(server.content, 'other device');
    // Further edits don't auto-save while the conflict is open.
    repo.edit('mine 2');
    await settle();
    expect(server.content, 'other device');
  });

  test('conflict: keep mine forces', () async {
    final repo = await makeRepo();
    server
      ..content = 'other'
      ..version = 1;
    repo.edit('mine');
    await settle();
    await repo.resolveConflict(ConflictChoice.keepMine);
    expect(server.content, 'mine');
    expect(repo.version, 2);
    expect(repo.status, SyncStatus.saved);
  });

  test("conflict: use server's", () async {
    final repo = await makeRepo();
    server
      ..content = 'other'
      ..version = 1;
    repo.edit('mine');
    await settle();
    await repo.resolveConflict(ConflictChoice.useServer);
    expect(repo.content, 'other');
    expect(repo.version, 1);
    expect(repo.dirty, isFalse);
    expect(repo.status, SyncStatus.saved);
  });

  test('conflict: save mine as copy keeps a local copy and takes server', () async {
    final repo = await makeRepo();
    server
      ..content = 'other'
      ..version = 1;
    repo.edit('mine');
    await settle();
    await repo.resolveConflict(ConflictChoice.saveMineAsCopy);
    expect(repo.content, 'other');
    expect(repo.conflictCopies.single.content, 'mine');
  });

  test('edits made during an in-flight save are not lost', () async {
    final repo = await makeRepo();
    server.holdSave = Completer();
    repo.edit('one');
    await settle(); // save of 'one' now in flight
    repo.edit('one two');
    server.holdSave!.complete();
    server.holdSave = null;
    await settle();
    await settle();
    expect(server.content, 'one two');
    expect(server.version, 2);
    expect(repo.dirty, isFalse);
  });

  test('unicode round-trips', () async {
    final repo = await makeRepo();
    const text = '# નમસ્તે 🙏\n- हिंदी\n| a | b |\n|---|---|\n';
    repo.edit(text);
    await settle();
    expect(server.content, text);
  });
}
