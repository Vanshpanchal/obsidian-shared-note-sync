import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'asset_info.dart';
import 'shared_api.dart';

class AssetList {
  const AssetList(this.files, this.maxBytes);
  final List<AssetInfo> files;

  /// Largest file the server accepts.
  final int maxBytes;
}

/// The name is already taken (and `overwrite` was not requested).
class AssetExistsException implements Exception {
  const AssetExistsException(this.name);
  final String name;
  @override
  String toString() => 'A file named "$name" already exists';
}

class AssetTooLargeException implements Exception {
  const AssetTooLargeException(this.maxBytes);
  final int maxBytes;
  @override
  String toString() => 'File is too large (max ${formatBytes(maxBytes)})';
}

/// The server answered with fewer bytes than the file has. Never saved or shown.
class AssetTruncatedException implements Exception {
  const AssetTruncatedException(this.got, this.expected);
  final int got;
  final int expected;
  @override
  String toString() => 'Download was cut short ($got of $expected bytes)';
}

/// Attachments endpoints of the `shared-api` function:
/// `GET /assets`, and `GET|POST|DELETE /assets/file?name=…`.
class AssetsApi {
  AssetsApi({required this.endpoint, required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  final String endpoint;
  final String apiKey;
  final http.Client _client;

  // Uploads and downloads move real bytes, so they get longer than note saves.
  static const _timeout = Duration(seconds: 60);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$endpoint/assets$path').replace(queryParameters: query);

  /// `/assets/file` URL with strict percent-encoding (space -> %20, + -> %2B).
  /// Dart's `queryParameters` writes a space as `+`, which the server does not
  /// decode back, so "a b.pdf" would be stored and looked up under another id.
  /// [rawPlus] sends `+` unescaped, to reach files uploaded that way before.
  Uri _fileUri(
    String name, {
    Map<String, String> extra = const {},
    bool rawPlus = false,
  }) {
    var n = Uri.encodeQueryComponent(
      name,
      encoding: utf8,
    ).replaceAll('+', '%20');
    if (rawPlus) n = n.replaceAll('%2B', '+');
    final rest = extra.entries
        .map((e) => '&${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join();
    return Uri.parse('$endpoint/assets/file?name=$n$rest');
  }

  Map<String, String> get _headers => {'x-api-key': apiKey};

  /// Headers for loading a file directly (images go through `cached_network_image`).
  Map<String, String> get authHeaders => {'x-api-key': apiKey};

  /// Where one file's bytes are served.
  String fileUrl(String name) => _fileUri(name).toString();

  Future<AssetList> list() async {
    final res = await _send(() => _client.get(_uri(''), headers: _headers));
    if (res.statusCode != 200) throw _error(res);
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return AssetList([
      for (final f in (json['files'] as List? ?? const []))
        AssetInfo.fromJson(f as Map<String, dynamic>),
    ], (json['maxBytes'] as num?)?.toInt() ?? 10 * 1024 * 1024);
  }

  Future<AssetInfo> upload(
    String name,
    Uint8List bytes, {
    bool overwrite = false,
  }) async {
    final res = await _send(
      () => _client.post(
        _fileUri(name, extra: {if (overwrite) 'overwrite': 'true'}),
        headers: {..._headers, 'content-type': 'application/octet-stream'},
        body: bytes,
      ),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return AssetInfo.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
      );
    }
    if (res.statusCode == 409) throw AssetExistsException(name);
    if (res.statusCode == 413) {
      var max = 0;
      try {
        max =
            ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['maxBytes'] as num)
                .toInt();
      } catch (_) {}
      throw AssetTooLargeException(max);
    }
    throw _error(res);
  }

  /// Downloads a file and checks its length against the listing, so a body cut off
  /// by a proxy or function limit is reported instead of saved.
  Future<Uint8List> download(AssetInfo info) async {
    var res = await _send(
      () => _client.get(_fileUri(info.name), headers: _headers),
    );
    // Files uploaded before the encoding fix are only reachable with a raw `+`.
    if (res.statusCode == 404 && info.name.contains('+')) {
      res = await _send(
        () =>
            _client.get(_fileUri(info.name, rawPlus: true), headers: _headers),
      );
    }
    if (res.statusCode != 200) throw _error(res);
    final bytes = res.bodyBytes;
    final declared =
        int.tryParse(res.headers['x-asset-size'] ?? '') ?? info.size;
    final expected = declared > 0 ? declared : info.size;
    if (bytes.length != expected || bytes.length != info.size) {
      throw AssetTruncatedException(bytes.length, info.size);
    }
    return bytes;
  }

  Future<void> delete(String name) async {
    var res = await _send(
      () => _client.delete(_fileUri(name), headers: _headers),
    );
    // Files uploaded before the encoding fix are only reachable with a raw `+`.
    if (res.statusCode == 404 && name.contains('+')) {
      res = await _send(
        () => _client.delete(_fileUri(name, rawPlus: true), headers: _headers),
      );
    }
    // Already gone counts as deleted.
    if (res.statusCode != 200 && res.statusCode != 404) throw _error(res);
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

  ApiException _error(http.Response res) {
    var message = res.reasonPhrase ?? 'error';
    try {
      message =
          ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['error']
              as String?) ??
          message;
    } catch (_) {}
    if (res.statusCode == 401) message = 'Invalid API key';
    if (res.statusCode == 501) {
      message = 'Attachments are not set up on the server yet';
    }
    if (res.statusCode == 400 && message == 'invalid_name') {
      message = 'That file name isn’t allowed';
    }
    return ApiException(res.statusCode, message);
  }

  void close() => _client.close();
}
