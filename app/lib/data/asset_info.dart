import 'dart:convert';

enum AssetKind { image, pdf, audio, video, text, archive, other }

/// One attachment as listed by the server (`GET /assets`).
class AssetInfo {
  const AssetInfo({
    required this.name,
    required this.size,
    required this.mimeType,
    this.createdAt,
    this.updatedAt,
  });

  factory AssetInfo.fromJson(Map<String, dynamic> json) => AssetInfo(
    name: json['name'] as String,
    size: (json['size'] as num?)?.toInt() ?? 0,
    mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
    createdAt: json['createdAt'] as String?,
    updatedAt: json['updatedAt'] as String?,
  );

  final String name;
  final int size;
  final String mimeType;
  final String? createdAt;
  final String? updatedAt;

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'mimeType': mimeType,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  AssetKind get kind => assetKindOf(name);
  bool get isImage => kind == AssetKind.image;

  /// Changes whenever the file is replaced, so cached bytes are never stale.
  String get cacheKey => '$name|$size|$updatedAt';

  DateTime? get modified =>
      DateTime.tryParse(updatedAt ?? createdAt ?? '')?.toLocal();

  /// The wikilink that points at this file. Images embed (`![[…]]`), the rest link.
  String get link => isImage ? '![[$name]]' : '[[$name]]';

  static String encodeList(List<AssetInfo> files) =>
      jsonEncode([for (final f in files) f.toJson()]);

  static List<AssetInfo> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final j in (jsonDecode(raw) as List))
          AssetInfo.fromJson(j as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
}

const _images = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'avif',
  'svg',
};
const _audio = {'mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac', 'webm'};
const _video = {'mp4', 'mov', 'mkv', 'ogv', 'm4v', 'avi'};
const _text = {'txt', 'md', 'csv', 'json', 'log', 'yaml', 'yml', 'xml', 'html'};
const _archive = {'zip', 'gz', 'tar', '7z', 'rar'};

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

AssetKind assetKindOf(String name) {
  final ext = extensionOf(name);
  if (_images.contains(ext)) return AssetKind.image;
  if (ext == 'pdf') return AssetKind.pdf;
  if (_audio.contains(ext)) return AssetKind.audio;
  if (_video.contains(ext)) return AssetKind.video;
  if (_text.contains(ext)) return AssetKind.text;
  if (_archive.contains(ext)) return AssetKind.archive;
  return AssetKind.other;
}

/// `2.4 MB`, `812 KB`, `64 B`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}

/// Rules shared with the server and the Obsidian plugin: plain file names that
/// can't break a `[[wikilink]]`.
class AssetNames {
  AssetNames._();

  static final _bad = RegExp(r'[\u0000-\u001f\u007f/\\:*?"<>|#^\[\]]');

  /// Turns anything a picker returns into a name the server accepts.
  static String sanitize(String raw) {
    var name = raw.replaceAll(_bad, '-').replaceAll(RegExp(r'\s+'), ' ').trim();
    name = name
        .replaceAll(RegExp(r'^\.+'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    if (name.isEmpty) name = 'File';
    if (name.length > 200) {
      final ext = extensionOf(name);
      final keep = 200 - (ext.isEmpty ? 0 : ext.length + 1);
      name = ext.isEmpty
          ? name.substring(0, 200)
          : '${name.substring(0, keep)}.$ext';
    }
    return name;
  }

  /// `photo.png` -> `photo (2).png` until it no longer collides (case-insensitive,
  /// like the server and Obsidian on macOS/Windows).
  static String unique(String desired, Iterable<String> existing) {
    final taken = {for (final n in existing) n.toLowerCase()};
    if (!taken.contains(desired.toLowerCase())) return desired;
    final dot = desired.lastIndexOf('.');
    final stem = dot > 0 ? desired.substring(0, dot) : desired;
    final ext = dot > 0 ? desired.substring(dot) : '';
    for (var i = 2; ; i++) {
      final candidate = '$stem ($i)$ext';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// The file name a wikilink target points at: drops `#heading` / `#^block`, a folder
  /// prefix (`Shared/assets/x.png`), and surrounding spaces.
  static String fromTarget(String target) {
    var t = target.trim();
    final hash = t.indexOf('#');
    if (hash >= 0) t = t.substring(0, hash);
    final slash = t.lastIndexOf('/');
    if (slash >= 0) t = t.substring(slash + 1);
    return t.trim();
  }

  /// `Photo 20261004-110300.jpg` for pictures that come without a useful name.
  static String stamped(String prefix, String ext, DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '$prefix $stamp${ext.isEmpty ? '' : '.$ext'}';
  }
}
