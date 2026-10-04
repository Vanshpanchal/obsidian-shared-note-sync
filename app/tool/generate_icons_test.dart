// Renders the VaultBridge app icon into the iOS, macOS and Android icon sets.
//
//   flutter test tool/generate_icons_test.dart
//
// Geometry comes from the design's "App icon & mark" artboard: two points joined
// by one bridge arc on a 48-unit grid. Stroke and dot size grow as the icon
// shrinks so the mark stays legible at 29 px.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

const _graphite = ui.Color(0xFF1C1B22);
const _line = ui.Color(0xFF34323D);
const _violet = ui.Color(0xFFA48BFA);

/// (arc stroke, dot radius) in 48-unit space, by rendered pixel size.
(double, double) _weights(double px) {
  if (px <= 32) return (6, 7);
  if (px <= 48) return (5, 6.5);
  if (px <= 72) return (4.5, 6);
  return (4, 5.5);
}

/// Draws the mark centred in a [box]-sized square at [cx], [cy].
void _mark(ui.Canvas c, double cx, double cy, double box, ui.Color color, {bool baseline = true}) {
  final k = box / 48;
  final (stroke, r) = _weights(box / 0.68);
  c.save();
  c.translate(cx - box / 2, cy - box / 2);
  c.scale(k);
  if (baseline && box / 0.68 >= 80) {
    c.drawLine(
      const ui.Offset(8, 34),
      const ui.Offset(40, 34),
      ui.Paint()
        ..color = _line
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = ui.StrokeCap.round
        ..isAntiAlias = true,
    );
  }
  final arc = ui.Path()
    ..moveTo(10, 32)
    ..cubicTo(10, 13, 38, 13, 38, 32);
  c.drawPath(
    arc,
    ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = ui.StrokeCap.round
      ..isAntiAlias = true,
  );
  final dot = ui.Paint()
    ..color = color
    ..isAntiAlias = true;
  c.drawCircle(const ui.Offset(10, 32), r, dot);
  c.drawCircle(const ui.Offset(38, 32), r, dot);
  c.restore();
}

enum _Style {
  /// Opaque full-bleed square (iOS masks it itself).
  square,

  /// Rounded tile on transparent, filling the canvas (legacy Android).
  tile,

  /// Rounded tile inset like a macOS icon.
  mac,

  /// Mark only, on transparent: Android adaptive foreground (66/108 safe zone).
  foreground,
}

Future<List<int>> _render(int px, _Style style) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final s = px.toDouble();
  final bg = ui.Paint()
    ..color = _graphite
    ..isAntiAlias = true;
  switch (style) {
    case _Style.square:
      c.drawRect(ui.Rect.fromLTWH(0, 0, s, s), bg);
      _mark(c, s / 2, s / 2, s * 0.68, _violet);
    case _Style.tile:
      c.drawRRect(
        ui.RRect.fromRectAndRadius(ui.Rect.fromLTWH(0, 0, s, s), ui.Radius.circular(s * 0.23)),
        bg,
      );
      _mark(c, s / 2, s / 2, s * 0.68, _violet);
    case _Style.mac:
      final body = s * 824 / 1024;
      final o = (s - body) / 2;
      c.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(o, o, body, body),
          ui.Radius.circular(body * 0.225),
        ),
        bg,
      );
      _mark(c, s / 2, s / 2, body * 0.68, _violet);
    case _Style.foreground:
      // Design: 64 px mark in a 108 px adaptive tile.
      _mark(c, s / 2, s / 2, s * 64 / 108, _violet, baseline: false);
  }
  final image = await rec.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _appiconset(String dir, _Style style) async {
  final json = jsonDecode(File('$dir/Contents.json').readAsStringSync()) as Map<String, dynamic>;
  final done = <String>{};
  for (final img in (json['images'] as List).cast<Map<String, dynamic>>()) {
    final name = img['filename'] as String?;
    if (name == null || !done.add(name)) continue;
    final size = double.parse((img['size'] as String).split('x').first);
    final scale = double.parse((img['scale'] as String).replaceAll('x', ''));
    File('$dir/$name').writeAsBytesSync(await _render((size * scale).round(), style));
  }
}

void main() {
  testWidgets('generate app icons', (tester) async {
    await tester.runAsync(() async {
      await _appiconset('ios/Runner/Assets.xcassets/AppIcon.appiconset', _Style.square);
      await _appiconset('macos/Runner/Assets.xcassets/AppIcon.appiconset', _Style.mac);

      const res = 'android/app/src/main/res';
      const legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
      for (final e in legacy.entries) {
        File(
          '$res/mipmap-${e.key}/ic_launcher.png',
        ).writeAsBytesSync(await _render(e.value, _Style.tile));
        // Adaptive layers are 108 dp.
        File(
          '$res/mipmap-${e.key}/ic_launcher_foreground.png',
        ).writeAsBytesSync(await _render((e.value * 108 / 48).round(), _Style.foreground));
      }
      Directory('$res/mipmap-anydpi-v26').createSync(recursive: true);
      File('$res/mipmap-anydpi-v26/ic_launcher.xml').writeAsStringSync(
        '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''',
      );
      File('$res/values/ic_launcher_background.xml').writeAsStringSync(
        '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#1C1B22</color>
</resources>
''',
      );
    });
  });
}
