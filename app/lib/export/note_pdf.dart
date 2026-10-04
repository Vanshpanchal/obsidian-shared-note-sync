import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/asset_info.dart';
import '../data/assets_repository.dart';
import '../markdown/obsidian_markdown.dart';
import '../theme/vb_theme.dart';

/// Renders [markdown] exactly as the preview shows it (callouts, math, mermaid,
/// attached pictures) and returns it as an A4 PDF.
///
/// The note is laid out off-screen at a fixed width, painted to bitmaps and cut into
/// pages, so what you see in the app is what lands in the file.
Future<Uint8List> renderNotePdf({
  required BuildContext context,
  required String markdown,
  required AssetsRepository assets,
  required ObsidianCallbacks callbacks,
}) async {
  // Fetch every attachment the note embeds first, so pictures are in the cache
  // (and the export fails loudly offline instead of printing empty frames).
  for (final info in _embeddedAssets(markdown, assets)) {
    if (info.isImage) await assets.bytes(info);
  }
  if (!context.mounted) throw StateError('Export cancelled');

  const pageWidth = 720.0; // logical px; matches ~A4 width at 1.0 text scale
  const pixelRatio = 2.0;
  final boundaryKey = GlobalKey();
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = buildVbTheme(Brightness.light);
  final mq = MediaQuery.of(context);

  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -(pageWidth + 200),
      top: 0,
      width: pageWidth,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: MediaQuery(
            data: mq.copyWith(
              size: Size(pageWidth, mq.size.height),
              textScaler: TextScaler.noScaling,
            ),
            child: Theme(
              data: theme,
              child: UnconstrainedBox(
                constrainedAxis: Axis.horizontal,
                alignment: Alignment.topLeft,
                child: Material(
                  color: theme.scaffoldBackgroundColor,
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: ColoredBox(
                      color: theme.scaffoldBackgroundColor,
                      child: Padding(
                        padding: const EdgeInsets.all(Vb.space4),
                        child: _NoteBody(
                          markdown: markdown,
                          callbacks: callbacks,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  overlay.insert(entry);
  try {
    final boundary = await _settled(boundaryKey);
    final width = boundary.size.width;
    final height = boundary.size.height;
    // `layer` lets us rasterise one page-sized slice at a time instead of one huge
    // bitmap that would blow past the GPU texture limit on long notes.
    // ignore: invalid_use_of_protected_member
    final layer = boundary.layer! as OffsetLayer;

    const format = PdfPageFormat.a4;
    const margin = 28.0; // PDF points
    final printableW = format.width - 2 * margin;
    final printableH = format.height - 2 * margin;
    // Logical px of the capture that fill one page.
    final sliceH = printableH * (width / printableW);

    final doc = pw.Document(title: 'shared.md', creator: 'VaultBridge');
    final bg = theme.scaffoldBackgroundColor;
    var top = 0.0;
    var pageNo = 0;
    while (top < height - 0.5) {
      pageNo++;
      var h = (height - top).clamp(0.0, sliceH);
      // Not the last page: cut in the last blank gap instead of mid-line.
      if (top + h < height - 0.5) {
        h = await _breakAt(layer, width, top, h, bg);
      }
      final image = await layer.toImage(
        Rect.fromLTWH(0, top, width, h),
        pixelRatio: pixelRatio,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('Couldn’t render page $pageNo');
      final png = pw.MemoryImage(data.buffer.asUint8List());
      final drawH = h * (printableW / width);
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(margin),
          build: (_) => pw.Align(
            alignment: pw.Alignment.topLeft,
            child: pw.Image(
              png,
              width: printableW,
              height: drawH,
              fit: pw.BoxFit.fill,
            ),
          ),
        ),
      );
      top += h;
    }
    return doc.save();
  } finally {
    entry.remove();
  }
}

/// Height (<= [h]) at which to end the page starting at [top]: the lowest fully
/// background-coloured row in the bottom third, i.e. the gap between two blocks.
/// Falls back to [h] when a block (e.g. a tall picture) fills that whole stretch.
Future<double> _breakAt(
  OffsetLayer layer,
  double width,
  double top,
  double h,
  Color bg,
) async {
  final from = top + h * 0.65;
  final rows = (top + h - from).floor();
  if (rows < 2) return h;
  final image = await layer.toImage(
    Rect.fromLTWH(0, from, width, rows.toDouble()),
    pixelRatio: 1,
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = image.width;
  final imgRows = image.height;
  image.dispose();
  if (data == null) return h;
  final r = (bg.r * 255).round(),
      g = (bg.g * 255).round(),
      b = (bg.b * 255).round();
  bool blank(int row) {
    for (var x = 0; x < w; x++) {
      final o = (row * w + x) * 4;
      if ((data.getUint8(o) - r).abs() > 3 ||
          (data.getUint8(o + 1) - g).abs() > 3 ||
          (data.getUint8(o + 2) - b).abs() > 3) {
        return false;
      }
    }
    return true;
  }

  for (var row = imgRows - 1; row >= 0; row--) {
    if (blank(row)) return (from - top) + row * (rows / imgRows);
  }
  return h;
}

/// Attachments mentioned as `![[name]]` or `[[name]]`, resolved against [assets].
Iterable<AssetInfo> _embeddedAssets(String markdown, AssetsRepository assets) {
  final seen = <String>{};
  final out = <AssetInfo>[];
  for (final m in RegExp(r'!?\[\[([^\]\n]+)\]\]').allMatches(markdown)) {
    final target = m.group(1)!.split('|').first.split('#').first.trim();
    if (!seen.add(target)) continue;
    final info = assets.find(target);
    if (info != null) out.add(info);
  }
  return out;
}

/// Waits until the off-screen tree has laid out, images and diagrams have settled
/// (height stops changing and no frame is pending), and returns its boundary.
Future<RenderRepaintBoundary> _settled(GlobalKey key) async {
  final binding = WidgetsBinding.instance;
  double? last;
  var stable = 0;
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await binding.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final box =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (box == null || !box.hasSize) continue;
    stable = (last == box.size.height && !binding.hasScheduledFrame)
        ? stable + 1
        : 0;
    last = box.size.height;
    if (stable >= 3) return box;
  }
  final box = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (box == null || !box.hasSize) {
    throw StateError('Couldn’t lay out the note');
  }
  return box;
}

class _NoteBody extends StatelessWidget {
  const _NoteBody({required this.markdown, required this.callbacks});

  final String markdown;
  final ObsidianCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final note = splitFrontmatter(markdown);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note.properties != null || note.rawFrontmatter != null)
          PropertiesPanel(
            properties: note.properties,
            raw: note.rawFrontmatter,
          ),
        ObsidianMarkdownBody(data: note.body, callbacks: callbacks),
      ],
    );
  }
}
