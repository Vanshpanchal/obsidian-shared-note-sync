import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class SharedState {
  const SharedState({
    required this.content,
    required this.version,
    this.updatedAt,
  });

  factory SharedState.fromJson(Map<String, dynamic> json) => SharedState(
    content: json['content'] as String? ?? '',
    version: (json['version'] as num?)?.toInt() ?? 0,
    updatedAt: json['updatedAt'] as String?,
  );

  final String content;
  final int version;
  final String? updatedAt;
}

sealed class SaveResult {
  const SaveResult();
}

class SaveOk extends SaveResult {
  const SaveOk(this.version, this.updatedAt);
  final int version;
  final String? updatedAt;
}

class SaveConflict extends SaveResult {
  const SaveConflict(this.server);
  final SharedState server;
}

/// Network unreachable / timed out. The caller should keep the edit and retry.
class OfflineException implements Exception {
  const OfflineException(this.cause);
  final Object cause;
  @override
  String toString() => 'Offline: $cause';
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'HTTP $statusCode: $message';
}

String normalizeLineEndings(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

class SharedApi {
  SharedApi({required this.endpoint, required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  final String endpoint;
  final String apiKey;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Uri _uri({bool force = false}) => Uri.parse(
    '$endpoint/shared',
  ).replace(queryParameters: force ? {'force': 'true'} : null);

  Map<String, String> get _headers => {
    'x-api-key': apiKey,
    'content-type': 'application/json; charset=utf-8',
  };

  Future<SharedState> get() async {
    final res = await _send(() => _client.get(_uri(), headers: _headers));
    if (res.statusCode != 200) throw _error(res);
    return SharedState.fromJson(_json(res));
  }

  Future<SaveResult> save({
    required String content,
    required int baseVersion,
    required String deviceId,
    bool force = false,
  }) async {
    final body = jsonEncode({
      'content': normalizeLineEndings(content),
      'baseVersion': baseVersion,
      'deviceId': deviceId,
    });
    final res = await _send(
      () => _client.post(
        _uri(force: force),
        headers: _headers,
        body: body,
      ),
    );
    switch (res.statusCode) {
      case 200:
        final j = _json(res);
        return SaveOk((j['version'] as num).toInt(), j['updatedAt'] as String?);
      case 409:
        return SaveConflict(SharedState.fromJson(_json(res)));
      default:
        throw _error(res);
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on SocketException catch (e) {
      throw OfflineException(e);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    } on HandshakeException catch (e) {
      throw OfflineException(e);
    }
  }

  Map<String, dynamic> _json(http.Response res) =>
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

  ApiException _error(http.Response res) {
    var message = res.reasonPhrase ?? 'error';
    try {
      message = (_json(res)['error'] as String?) ?? message;
    } catch (_) {}
    if (res.statusCode == 401) message = 'Invalid API key';
    if (res.statusCode == 413) message = 'Document too large (max 1 MB)';
    return ApiException(res.statusCode, message);
  }

  void close() => _client.close();
}
