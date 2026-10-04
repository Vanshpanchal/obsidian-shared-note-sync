import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
// mermaid_core has its own Color/Rect/Point/Size, so it is always used with a prefix.
import 'package:mermaid_core/mermaid_core.dart' as m;

import '../theme/vb_theme.dart';
import 'mermaid_theme_clone.dart';

/// Measures text with Flutter's own text engine, so a diagram is laid out with the same
/// font metrics it is painted with (the pure-Dart fallback only approximates them).
class FlutterTextMeasurer implements m.TextMeasurer {
  const FlutterTextMeasurer();

  @override
  m.Size measure(String text, m.TextStyleSpec style, {double? maxWidth}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyleFor(style)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    final size = m.Size(painter.width, painter.height);
    painter.dispose();
    return size;
  }
}

TextStyle textStyleFor(m.TextStyleSpec s, {Color? color}) => TextStyle(
  fontFamily: Vb.sans,
  fontSize: s.fontSize,
  fontWeight: FontWeight.values[((s.fontWeight / 100).round() - 1).clamp(0, 8)],
  fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
  color: color,
  height: 1.2,
);

m.Color _mc(Color c) => m.Color(c.toARGB32());

/// The app's palette applied to a mermaid theme, so diagrams look like the rest of the note
/// (violet nodes on the code-block background, charts in the callout colours) instead of
/// mermaid's stock colours.
m.MermaidTheme mermaidThemeFor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final vb = context.vb;
  final dark = Theme.of(context).brightness == Brightness.dark;

  // Distinct hues that keep contrast in both themes (they are the tokens' own variants).
  final palette = <Color>[
    scheme.primary,
    vb.success,
    vb.warning,
    vb.info,
    scheme.error,
    vb.calloutAbstract,
    vb.calloutWarning,
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.35), scheme.primary),
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.35), vb.success),
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.35), vb.info),
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.35), vb.warning),
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.35), scheme.error),
  ];

  final colors = <String, m.Color>{
    // Nodes, lines and text.
    'background': m.Color.transparent,
    'primaryColor': _mc(scheme.primaryContainer),
    'primaryTextColor': _mc(scheme.onSurface),
    'primaryBorderColor': _mc(scheme.primary),
    'secondaryColor': _mc(scheme.surfaceContainerHigh),
    'lineColor': _mc(scheme.onSurfaceVariant),
    'arrowheadColor': _mc(scheme.onSurfaceVariant),
    'textColor': _mc(scheme.onSurface),
    'nodeBorder': _mc(scheme.primary),
    'mainBkg': _mc(scheme.primaryContainer),
    'clusterBkg': _mc(scheme.surfaceContainerHigh),
    'clusterBorder': _mc(scheme.outline),
    'titleColor': _mc(scheme.onSurface),
    'edgeLabelBackground': _mc(vb.codeBg),
    // Pie.
    'pieStrokeColor': _mc(vb.codeBg),
    'pieOuterStrokeColor': _mc(scheme.outlineVariant),
    'pieSectionTextColor': _mc(scheme.onPrimary),
    'pieLegendTextColor': _mc(scheme.onSurface),
    'pieTitleTextColor': _mc(scheme.onSurface),
    // Sequence.
    'actorBkg': _mc(scheme.surfaceContainerHigh),
    'actorBorder': _mc(scheme.primary),
    'actorTextColor': _mc(scheme.onSurface),
    'actorLineColor': _mc(scheme.outline),
    'signalColor': _mc(scheme.onSurfaceVariant),
    'signalTextColor': _mc(scheme.onSurface),
    'labelBoxBkgColor': _mc(scheme.primaryContainer),
    'labelBoxBorderColor': _mc(scheme.primary),
    'labelTextColor': _mc(scheme.onSurface),
    'loopTextColor': _mc(scheme.onSurface),
    'noteBkgColor': _mc(vb.warningContainer),
    'noteBorderColor': _mc(vb.warning),
    'noteTextColor': _mc(scheme.onSurface),
    'activationBkgColor': _mc(scheme.surfaceContainerHigh),
    'activationBorderColor': _mc(scheme.outline),
  };
  for (var i = 0; i < palette.length; i++) {
    colors['pie${i + 1}'] = _mc(palette[i]);
    colors['cScale$i'] = _mc(palette[i]);
    colors['cScaleLabel$i'] = _mc(scheme.onPrimary);
  }

  return cloneMermaidTheme(
    dark ? m.MermaidTheme.darkTheme : m.MermaidTheme.defaultTheme,
    colors: colors,
    fontFamily: Vb.sans,
    fontSize: 14,
    xyChartPlotColorPalette: [for (final c in palette) _mc(c)],
  );
}

/// A laid-out diagram, or the reason it couldn't be drawn.
class MermaidResult {
  const MermaidResult._({this.renderer, this.error, this.unsupported = false});

  /// Ready to paint.
  final SceneRenderer? renderer;
  final String? error;

  /// A diagram type mermaid_core hasn't ported (shown as source, like before).
  final bool unsupported;

  bool get ok => renderer != null;

  static MermaidResult render(String source, m.MermaidTheme theme) {
    try {
      final scene = m.Mermaid(
        measurer: const FlutterTextMeasurer(),
        theme: theme,
      ).render(source);
      return MermaidResult._(renderer: SceneRenderer(scene));
    } on m.MermaidParseException catch (e) {
      final where = e.line == null ? '' : ' (line ${e.line})';
      return MermaidResult._(error: '${e.message}$where');
    } on UnsupportedError catch (e) {
      return MermaidResult._(
        error: e.message ?? 'Unsupported diagram',
        unsupported: true,
      );
    } catch (e) {
      return MermaidResult._(error: 'Couldn’t draw this diagram: $e');
    }
  }
}

/// Turns a mermaid_core scene into Flutter paint calls once, then replays them each frame.
class SceneRenderer {
  SceneRenderer(this.scene) {
    for (final node in scene.nodes) {
      _add(node);
    }
  }

  final m.RenderScene scene;
  final _ops = <void Function(Canvas)>[];

  Size get size => Size(scene.size.width, scene.size.height);

  void paint(Canvas canvas) {
    for (final op in _ops) {
      op(canvas);
    }
  }

  void _add(m.SceneNode node) {
    switch (node) {
      case m.SceneGroup():
        for (final child in node.children) {
          _add(child);
        }
      case m.SceneShape():
        _addShape(node);
      case m.SceneText():
        _addText(node);
    }
  }

  Offset _o(m.Point p) => Offset(p.x, p.y);

  Path _path(m.ShapeGeometry g) {
    final path = Path();
    switch (g) {
      case m.RectGeometry():
        final r = Rect.fromLTWH(
          g.rect.left,
          g.rect.top,
          g.rect.width,
          g.rect.height,
        );
        if (g.rx > 0 || g.ry > 0) {
          path.addRRect(RRect.fromRectXY(r, g.rx, g.ry == 0 ? g.rx : g.ry));
        } else {
          path.addRect(r);
        }
      case m.CircleGeometry():
        path.addOval(Rect.fromCircle(center: _o(g.center), radius: g.radius));
      case m.EllipseGeometry():
        path.addOval(
          Rect.fromCenter(
            center: _o(g.center),
            width: g.rx * 2,
            height: g.ry * 2,
          ),
        );
      case m.PolygonGeometry():
        path.addPolygon([for (final p in g.points) _o(p)], true);
      case m.PathGeometry():
        for (final c in g.commands) {
          switch (c) {
            case m.MoveTo():
              path.moveTo(c.p.x, c.p.y);
            case m.LineTo():
              path.lineTo(c.p.x, c.p.y);
            case m.CubicTo():
              path.cubicTo(c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.p.x, c.p.y);
            case m.QuadTo():
              path.quadraticBezierTo(c.c.x, c.c.y, c.p.x, c.p.y);
            case m.ClosePath():
              path.close();
          }
        }
    }
    return path;
  }

  Shader _gradient(m.SceneGradient g) => ui.Gradient.linear(
    _o(g.from),
    _o(g.to),
    [for (final c in g.colors) Color(c.value)],
  );

  void _addShape(m.SceneShape shape) {
    final path = _path(shape.geometry);
    final blend = shape.blendMode == m.SceneBlendMode.multiply
        ? BlendMode.multiply
        : BlendMode.srcOver;

    final fill = shape.fill;
    if (fill != null && fill.color.alpha > 0 || fill?.gradient != null) {
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true
        ..blendMode = blend;
      if (fill!.gradient != null) {
        paint.shader = _gradient(fill.gradient!);
      } else {
        paint.color = Color(fill.color.value);
      }
      _ops.add((c) => c.drawPath(path, paint));
    }

    final stroke = shape.stroke;
    if (stroke != null && stroke.width > 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..blendMode = blend;
      if (stroke.gradient != null) {
        paint.shader = _gradient(stroke.gradient!);
      } else {
        paint.color = Color(stroke.color.value);
      }
      final target = stroke.dash == null || stroke.dash!.isEmpty
          ? path
          : _dashed(path, stroke.dash!);
      _ops.add((c) => c.drawPath(target, paint));
    }
  }

  /// SVG-style dash array applied along a path.
  Path _dashed(Path source, List<double> dash) {
    final pattern = dash.length.isOdd ? [...dash, ...dash] : dash;
    if (pattern.every((d) => d <= 0)) return source;
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      var i = 0;
      while (distance < metric.length) {
        final len = math.max(pattern[i % pattern.length], 0.01);
        if (i.isEven) {
          out.addPath(
            metric.extractPath(
              distance,
              math.min(distance + len, metric.length),
            ),
            Offset.zero,
          );
        }
        distance += len;
        i++;
      }
    }
    return out;
  }

  void _addText(m.SceneText t) {
    final align = switch (t.align) {
      m.TextAlignH.left => TextAlign.left,
      m.TextAlignH.center => TextAlign.center,
      m.TextAlignH.right => TextAlign.right,
    };
    final painter =
        TextPainter(
          text: TextSpan(
            text: t.text,
            style: textStyleFor(t.style, color: Color(t.color.value)).copyWith(
              decoration: t.underline ? TextDecoration.underline : null,
            ),
          ),
          textAlign: align,
          textDirection: TextDirection.ltr,
        )..layout(
          minWidth: t.bounds.width,
          maxWidth: math.max(t.bounds.width, 1) + 4,
        );
    // A label measured at exactly its width must not wrap when painted (rounding), so the
    // painter gets a few pixels of slack and the block is re-aligned inside the real bounds.
    final center = Offset(
      t.bounds.left + t.bounds.width / 2,
      t.bounds.top + t.bounds.height / 2,
    );
    final dx = switch (t.align) {
      m.TextAlignH.left => t.bounds.left,
      m.TextAlignH.center => center.dx - painter.width / 2,
      m.TextAlignH.right => t.bounds.right - painter.width,
    };
    final topLeft = Offset(dx, center.dy - painter.height / 2);
    _ops.add((c) {
      if (t.rotation == 0) {
        painter.paint(c, topLeft);
        return;
      }
      c
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(t.rotation * math.pi / 180)
        ..translate(-center.dx, -center.dy);
      painter.paint(c, topLeft);
      c.restore();
    });
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.renderer, this.scale);

  final SceneRenderer renderer;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(scale);
    renderer.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.renderer != renderer || old.scale != scale;
}

/// A rendered diagram, scaled down to fit the available width.
class MermaidDiagram extends StatelessWidget {
  const MermaidDiagram({super.key, required this.renderer, this.maxWidth});

  final SceneRenderer renderer;

  /// Upper bound for the width; defaults to the parent's.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final available = math.min(box.maxWidth, maxWidth ?? double.infinity);
        final natural = renderer.size;
        if (natural.width <= 0 || natural.height <= 0)
          return const SizedBox.shrink();
        final scale = math.min(1.0, available / natural.width);
        return Semantics(
          image: true,
          label: 'Diagram',
          child: CustomPaint(
            size: Size(natural.width * scale, natural.height * scale),
            painter: _ScenePainter(renderer, scale),
          ),
        );
      },
    );
  }
}

/// Mermaid fence in the preview: the diagram, with "Source" and "Expand" actions.
/// Falls back to the source (as before) for syntax errors and unported diagram types.
class MermaidBlock extends StatefulWidget {
  const MermaidBlock({super.key, required this.source});

  final String source;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  MermaidResult? _result;
  Brightness? _renderedFor;
  String? _renderedSource;
  bool _showSource = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureRendered();
  }

  @override
  void didUpdateWidget(MermaidBlock old) {
    super.didUpdateWidget(old);
    _ensureRendered();
  }

  void _ensureRendered() {
    final brightness = Theme.of(context).brightness;
    if (_result != null &&
        _renderedFor == brightness &&
        _renderedSource == widget.source)
      return;
    _renderedFor = brightness;
    _renderedSource = widget.source;
    _result = MermaidResult.render(widget.source, mermaidThemeFor(context));
  }

  void _expand() {
    final result = _result!;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MermaidViewerScreen(renderer: result.renderer!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final reading = context.reading;
    final result = _result!;
    final diagram = result.ok && !_showSource;
    final syntaxError = !result.ok && !result.unsupported;

    final label = Text(
      'MERMAID',
      style: reading.codeLabel.copyWith(color: scheme.onSurfaceVariant),
    );

    Widget header() => Container(
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(child: label),
          if (result.unsupported)
            _pill(
              context,
              'RENDERS IN OBSIDIAN',
              scheme.primary,
              scheme.primaryContainer,
            )
          else if (syntaxError)
            _pill(context, 'SYNTAX ERROR', scheme.error, scheme.errorContainer)
          else ...[
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                minimumSize: const Size(48, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(
                  fontFamily: Vb.sans,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onPressed: () => setState(() => _showSource = !_showSource),
              child: Text(_showSource ? 'Diagram' : 'Source'),
            ),
            if (diagram)
              IconButton(
                tooltip: 'Open full screen',
                iconSize: 16,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: Icon(
                  LucideIcons.maximize2,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: _expand,
              ),
          ],
        ],
      ),
    );

    final source = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Text(
        widget.source,
        style: reading.code.copyWith(color: scheme.onSurfaceVariant),
      ),
    );

    return Container(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: vb.codeBg,
        borderRadius: BorderRadius.circular(Vb.radiusSm),
        border: Border.all(
          color: syntaxError
              ? scheme.error.withValues(alpha: 0.6)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(),
          if (syntaxError)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Text(
                result.error!,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: scheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          if (diagram)
            InkWell(
              onTap: _expand,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: MermaidDiagram(renderer: result.renderer!),
                ),
              ),
            )
          else
            source,
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, String text, Color fg, Color bg) =>
      Container(
        height: 22,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Vb.radiusPill),
        ),
        child: Text(text, style: context.reading.codeLabel.copyWith(color: fg)),
      );
}

/// Full-screen diagram: pinch, scroll-wheel or the buttons to zoom, drag to pan,
/// double-tap to zoom in (and again to fit). 100% means "fits the screen".
class MermaidViewerScreen extends StatefulWidget {
  const MermaidViewerScreen({super.key, required this.renderer});

  final SceneRenderer renderer;

  @override
  State<MermaidViewerScreen> createState() => _MermaidViewerScreenState();
}

class _MermaidViewerScreenState extends State<MermaidViewerScreen> {
  static const _margin = 24.0;
  static const _step = 1.4;

  final _controller = TransformationController();
  Size _viewport = Size.zero;
  double _fit = 1;
  Offset _lastTap = Offset.zero;

  Size get _natural => widget.renderer.size;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Scale on every axis is kept equal (see the matrices below), so getMaxScaleOnAxis is exact.
  double get _scale => _controller.value.getMaxScaleOnAxis();

  /// Fit the whole diagram on screen, centred.
  void _fitToScreen() {
    final n = _natural;
    if (n.width <= 0 || n.height <= 0 || _viewport.isEmpty) return;
    _fit = math
        .min(
          (_viewport.width - 2 * _margin) / n.width,
          (_viewport.height - 2 * _margin) / n.height,
        )
        .clamp(0.05, 3.0);
    final dx = (_viewport.width - n.width * _fit) / 2;
    final dy = (_viewport.height - n.height * _fit) / 2;
    _controller.value =
        Matrix4.translationValues(dx, dy, 0) *
        Matrix4.diagonal3Values(_fit, _fit, _fit);
  }

  /// Zoom by [factor] around [focal] (the viewport centre by default), within sane limits.
  void _zoomBy(double factor, [Offset? focal]) {
    final current = _scale;
    final target = (current * factor).clamp(_fit * 0.4, _fit * 14);
    final f = target / current;
    final c = focal ?? Offset(_viewport.width / 2, _viewport.height / 2);
    _controller.value =
        Matrix4.translationValues(c.dx, c.dy, 0) *
        Matrix4.diagonal3Values(f, f, f) *
        Matrix4.translationValues(-c.dx, -c.dy, 0) *
        _controller.value;
  }

  void _doubleTap() {
    // Near "fit": zoom in on the tapped point. Already zoomed in: back to fit.
    if (_scale <= _fit * 1.2) {
      _zoomBy(2.5, _lastTap);
    } else {
      _fitToScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = _natural;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(LucideIcons.arrowLeft, color: scheme.onSurface),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Diagram'),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final viewport = Size(box.maxWidth, box.maxHeight);
          if (viewport != _viewport) {
            // First layout, or the window/orientation changed: fit again.
            _viewport = viewport;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _fitToScreen();
            });
          }
          return Stack(
            children: [
              GestureDetector(
                onDoubleTapDown: (d) => _lastTap = d.localPosition,
                onDoubleTap: _doubleTap,
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  minScale: 0.02,
                  maxScale: 60,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: CustomPaint(
                    size: size,
                    painter: _ScenePainter(widget.renderer, 1),
                  ),
                ),
              ),
              Positioned(
                right: Vb.space4,
                bottom: Vb.space4 + MediaQuery.paddingOf(context).bottom,
                child: _ZoomControls(
                  controller: _controller,
                  fit: () => _fit,
                  onZoomIn: () => _zoomBy(_step),
                  onZoomOut: () => _zoomBy(1 / _step),
                  onFit: _fitToScreen,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.controller,
    required this.fit,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final TransformationController controller;
  final double Function() fit;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(IconData icon, String tooltip, VoidCallback onTap) =>
        IconButton(
          tooltip: tooltip,
          iconSize: 20,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: Icon(icon, color: scheme.onSurface),
          onPressed: onTap,
        );

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusPill),
        side: BorderSide(color: scheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Vb.space1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(LucideIcons.zoomOut, 'Zoom out', onZoomOut),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final percent =
                    (controller.value.getMaxScaleOnAxis() / fit() * 100)
                        .round();
                return SizedBox(
                  width: 52,
                  child: Text(
                    '$percent%',
                    textAlign: TextAlign.center,
                    semanticsLabel: 'Zoom $percent percent',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                );
              },
            ),
            button(LucideIcons.zoomIn, 'Zoom in', onZoomIn),
            Container(width: 1, height: 24, color: scheme.outlineVariant),
            button(LucideIcons.maximize, 'Fit to screen', onFit),
          ],
        ),
      ),
    );
  }
}
