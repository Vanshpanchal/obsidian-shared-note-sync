import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

import '../theme/vb_theme.dart';
import 'callouts.dart';
import 'find_in_note.dart';
import 'mermaid_view.dart';
import 'obsidian_syntaxes.dart';

/// Taps on things that point outside this note.
class ObsidianCallbacks {
  const ObsidianCallbacks({
    this.onWikiLink,
    this.onTag,
    this.onExternalLink,
    this.embedBuilder,
    this.finder,
  });

  /// Highlights the search query in the text when set (find in note).
  final NoteFinder? finder;

  /// Same callbacks without search highlighting (used for the PDF export).
  ObsidianCallbacks withoutFinder() => ObsidianCallbacks(
    onWikiLink: onWikiLink,
    onTag: onTag,
    onExternalLink: onExternalLink,
    embedBuilder: embedBuilder,
  );

  final void Function(String target)? onWikiLink;
  final void Function(String tag)? onTag;
  final void Function(String href)? onExternalLink;

  /// Draws `![[target]]` (e.g. the real picture for an attachment). Return null to fall
  /// back to the plain "Embedded: file" chip. [width] comes from `![[img.png|300]]`.
  final Widget? Function(BuildContext context, String target, double? width)?
  embedBuilder;
}

/// Scrollable reading view of an Obsidian note: properties panel + body.
class ObsidianMarkdownView extends StatelessWidget {
  const ObsidianMarkdownView({
    super.key,
    required this.data,
    this.callbacks = const ObsidianCallbacks(),
    this.padding = const EdgeInsets.all(16),
    this.footer,
  });

  final String data;
  final ObsidianCallbacks callbacks;
  final EdgeInsets padding;

  /// Shown after the note body (e.g. "End of shared.md").
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final note = splitFrontmatter(data);
    return SelectionArea(
      child: ListView(
        padding: padding,
        children: [
          if (note.properties != null || note.rawFrontmatter != null)
            PropertiesPanel(
              properties: note.properties,
              raw: note.rawFrontmatter,
              onTag: callbacks.onTag,
              finder: callbacks.finder,
            ),
          ObsidianMarkdownBody(data: note.body, callbacks: callbacks),
          ?footer,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- frontmatter

class SplitNote {
  const SplitNote(this.body, {this.properties, this.rawFrontmatter});
  final String body;

  /// Parsed YAML map, or null if absent/invalid.
  final Map<String, dynamic>? properties;

  /// Raw YAML when it couldn't be parsed (shown as-is).
  final String? rawFrontmatter;
}

final _frontmatter = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)');

SplitNote splitFrontmatter(String text) {
  final m = _frontmatter.firstMatch(text);
  if (m == null) return SplitNote(text);
  final body = text.substring(m.end);
  final yamlText = m[1]!;
  if (yamlText.trim().isEmpty) return SplitNote(body);
  try {
    final doc = loadYaml(yamlText);
    if (doc is YamlMap) {
      return SplitNote(body, properties: _plain(doc) as Map<String, dynamic>);
    }
  } catch (_) {}
  return SplitNote(body, rawFrontmatter: yamlText);
}

Object? _plain(Object? v) => switch (v) {
  YamlMap m => {for (final e in m.entries) e.key.toString(): _plain(e.value)},
  YamlList l => [for (final x in l) _plain(x)],
  _ => v,
};

class PropertiesPanel extends StatefulWidget {
  const PropertiesPanel({
    super.key,
    this.properties,
    this.raw,
    this.onTag,
    this.finder,
  });

  final NoteFinder? finder;

  final Map<String, dynamic>? properties;
  final String? raw;
  final void Function(String tag)? onTag;

  static IconData _iconFor(String key, Object? value) {
    switch (key) {
      case 'tags':
        return LucideIcons.tag;
      case 'aliases':
        return LucideIcons.split;
      case 'cssclasses':
        return LucideIcons.palette;
    }
    if (value is bool) return LucideIcons.squareCheck;
    if (value is num) return LucideIcons.hash;
    if (value is List) return LucideIcons.list;
    if (value is String && DateTime.tryParse(value) != null)
      return LucideIcons.calendar;
    if (value is DateTime) return LucideIcons.calendar;
    return LucideIcons.textAlignStart;
  }

  @override
  State<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<PropertiesPanel> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final rows = <Widget>[];

    if (widget.properties != null) {
      for (final MapEntry(:key, :value) in widget.properties!.entries) {
        final multi = value is List;
        rows.add(
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              crossAxisAlignment: multi
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 104,
                  height: 28,
                  child: Row(
                    children: [
                      Icon(
                        PropertiesPanel._iconFor(key, value),
                        size: 16,
                        color: muted,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: findText(
                          widget.finder,
                          key,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium!.copyWith(
                            fontSize: 14,
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _value(context, key, value)),
              ],
            ),
          ),
        );
      }
    } else if (widget.raw != null) {
      rows.add(
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(12),
          child: findText(
            widget.finder,
            widget.raw!,
            style: context.reading.code.copyWith(fontSize: 12),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Vb.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Properties',
                        style: theme.textTheme.labelMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.properties != null)
                      Text(
                        '${widget.properties!.length}',
                        style: theme.textTheme.labelMedium!.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...rows,
        ],
      ),
    );
  }

  Widget _value(BuildContext context, String key, Object? value) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(fontSize: 14, height: 21 / 14);
    if (value is List) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final v in value)
            key == 'tags'
                ? TagPill(
                    tag: v.toString().replaceFirst('#', ''),
                    onTap: widget.onTag,
                    finder: widget.finder,
                  )
                : Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(Vb.radiusPill),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: findText(
                        widget.finder,
                        v.toString(),
                        style: Theme.of(context).textTheme.labelLarge!.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
        ],
      );
    }
    if (value is bool) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: value ? scheme.primary : null,
            borderRadius: BorderRadius.circular(Vb.radiusXs),
            border: value
                ? null
                : Border.all(color: scheme.outline, width: 1.5),
          ),
          child: value
              ? Icon(LucideIcons.check, size: 14, color: scheme.onPrimary)
              : null,
        ),
      );
    }
    return findText(widget.finder, value?.toString() ?? '', style: style);
  }
}

// ---------------------------------------------------------------- body

/// Non-scrolling body; also used recursively inside callouts and details.
class ObsidianMarkdownBody extends StatelessWidget {
  const ObsidianMarkdownBody({
    super.key,
    required this.data,
    this.callbacks = const ObsidianCallbacks(),
    this.baseStyle,
  });

  final String data;
  final ObsidianCallbacks callbacks;

  /// Overrides the paragraph style (used for callout titles).
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    var sheet = obsidianStyleSheet(context);
    if (baseStyle != null) sheet = sheet.copyWith(p: baseStyle);

    final tasks = _TaskState();
    final finder = callbacks.finder;
    final query = finder?.query.value ?? '';
    return MarkdownBody(
      // The markdown is only re-parsed when its data changes; a new query needs a fresh parse.
      key: ValueKey(query),
      data: data,
      styleSheet: sheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: obsidianBlockSyntaxes(),
      inlineSyntaxes: [
        ...obsidianInlineSyntaxes(),
        if (finder != null && query.isNotEmpty) FindSyntax(query),
      ],
      builders: _builders(callbacks, tasks),
      checkboxBuilder: (checked) {
        final status = tasks.pending ?? (checked ? 'x' : ' ');
        tasks.pending = null;
        return Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: _taskBox(context, status),
        );
      },
      imageBuilder: (uri, title, alt) => _image(context, uri, alt, callbacks),
      onTapLink: (text, href, title) {
        if (href == null || href.startsWith('#')) {
          return; // footnote anchors etc.
        }
        final uri = Uri.tryParse(href);
        // `[manual](Shared/assets/manual.pdf)`: a vault path, not a web link.
        if (uri != null && !uri.hasScheme && callbacks.onWikiLink != null) {
          callbacks.onWikiLink!(_vaultPath(uri));
          return;
        }
        callbacks.onExternalLink?.call(href);
      },
    );
  }
}

/// Hands the status of a `- [/]`-style task from its inline node to the list
/// item's checkbox builder (the markdown package only passes a bool).
class _TaskState {
  String? pending;
}

Map<String, MarkdownElementBuilder> _builders(
  ObsidianCallbacks cb,
  _TaskState tasks,
) => {
  'obs-callout': _BlockBuilder(
    (context, el) => CalloutBox(
      type: el.attributes['type']!,
      title: el.attributes['title']!,
      fold: el.attributes['fold']!,
      titleBuilder: (context, title, style) =>
          ObsidianMarkdownBody(data: title, callbacks: cb, baseStyle: style),
      bodyBuilder: (context) =>
          ObsidianMarkdownBody(data: el.attributes['body']!, callbacks: cb),
    ),
  ),
  'obs-details': _BlockBuilder(
    (context, el) => _Details(
      finder: cb.finder,
      bodyText: el.attributes['body']!,
      summary: el.attributes['summary']!,
      initiallyOpen: el.attributes['open'] == 'true',
      body: ObsidianMarkdownBody(data: el.attributes['body']!, callbacks: cb),
    ),
  ),
  'obs-math-block': _BlockBuilder(
    (context, el) => _MathBlock(tex: el.attributes['tex']!),
  ),
  'pre': _BlockBuilder((context, el) {
    final code = el.children?.whereType<md.Element>().firstOrNull;
    final lang = (code?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    // The parser keeps the trailing newline of the fence content.
    final text = el.textContent.replaceFirst(RegExp(r'\n$'), '');
    return CodeBlock(code: text, language: lang, finder: cb.finder);
  }),
  'section': _BlockBuilder(
    (context, el) => _Footnotes(section: el, finder: cb.finder),
  ),
  'obs-wikilink': _SpanBuilder((context, el, base) {
    void open() => cb.onWikiLink!(el.attributes['target']!);
    return findSpan(
      cb.finder,
      el.textContent,
      base.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w500,
      ),
      recognizer: cb.onWikiLink == null
          ? null
          : (TapGestureRecognizer()..onTap = open),
      onTap: cb.onWikiLink == null ? null : open,
    );
  }),
  // Inline `code`, only while searching, so matches inside it are highlighted. (Fenced
  // code is drawn by CodeBlock from the `pre` element and ignores this.)
  if (cb.finder?.active ?? false)
    'code': _SpanBuilder(
      (context, el, base) => findSpan(cb.finder, el.textContent, base),
    ),
  'obs-find': _SpanBuilder(
    (context, el, base) => WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: FindMatch(finder: cb.finder!, text: el.textContent, style: base),
    ),
  ),
  'obs-tag': _SpanBuilder(
    (context, el, base) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: TagPill(
        tag: el.textContent,
        onTap: cb.onTag,
        compact: true,
        finder: cb.finder,
      ),
    ),
  ),
  'obs-mark': _SpanBuilder(
    (context, el, base) => findSpan(
      cb.finder,
      el.textContent,
      base.copyWith(
        backgroundColor: context.vb.highlight,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
  ),
  'obs-embed-block': _BlockBuilder((context, el) {
    final target = el.attributes['target']!;
    final width = double.tryParse(
      RegExp(r'^\d+').firstMatch(el.attributes['size'] ?? '')?[0] ?? '',
    );
    // Room above and below, so a label line right before the embed isn't crowded.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Vb.space2),
      child: Align(
        alignment: Alignment.centerLeft,
        child:
            cb.embedBuilder?.call(context, target, width) ??
            _EmbedChip(target: target, onTap: cb.onWikiLink, finder: cb.finder),
      ),
    );
  }),
  'obs-embed': _SpanBuilder((context, el, base) {
    final target = el.attributes['target']!;
    // `![[img.png|300]]` or `![[img.png|300x200]]`: only the width is used.
    final width = double.tryParse(
      RegExp(r'^\d+').firstMatch(el.attributes['size'] ?? '')?[0] ?? '',
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      // Padding keeps the chip off the text line above it (it is inline when the
      // `![[…]]` follows a label on the previous line with no blank line between).
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Vb.space2),
        child:
            cb.embedBuilder?.call(context, target, width) ??
            _EmbedChip(target: target, onTap: cb.onWikiLink, finder: cb.finder),
      ),
    );
  }),
  'obs-inline-fn': _SpanBuilder(
    (context, el, base) => WidgetSpan(
      alignment: PlaceholderAlignment.top,
      child: Tooltip(
        message: el.textContent,
        triggerMode: TooltipTriggerMode.tap,
        child: Text(
          '[*]',
          style: base.copyWith(
            fontSize: (base.fontSize ?? 14) * 0.7,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ),
  ),
  'obs-math-inline': _SpanBuilder(
    (context, el, base) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Math.tex(
        el.attributes['tex']!,
        textStyle: base,
        mathStyle: MathStyle.text,
        onErrorFallback: (e) =>
            Text('\$${el.attributes['tex']}\$', style: base),
      ),
    ),
  ),
  'obs-html': _SpanBuilder(
    (context, el, base) =>
        _htmlSpan(context, el.attributes['kind']!, el.textContent, base),
  ),
  'obs-task': _SpanBuilder((context, el, base) {
    // Drawn by the checkbox builder, which the list item calls right after this.
    tasks.pending = el.attributes['status'];
    return const TextSpan(text: '');
  }),
};

class _BlockBuilder extends MarkdownElementBuilder {
  _BlockBuilder(this.builder);
  final Widget Function(BuildContext context, md.Element element) builder;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => builder(context, element);
}

/// Returns a Text.rich so flutter_markdown merges it into the surrounding paragraph.
class _SpanBuilder extends MarkdownElementBuilder {
  _SpanBuilder(this.builder);
  final InlineSpan Function(
    BuildContext context,
    md.Element element,
    TextStyle base,
  )
  builder;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final base = parentStyle ?? DefaultTextStyle.of(context).style;
    final span = builder(context, element, base);
    // flutter_markdown flattens nested spans and merges the *parent* style over
    // each child's, so a styled wrapper would erase link colors and highlights.
    // Return the fully styled span itself, or wrap it in an unstyled span.
    // A style-less span of styled children (see findSpan) is already flat.
    final flat =
        span is TextSpan &&
        (span.children == null || (span.style == null && span.text == null));
    return Text.rich(flat ? span : TextSpan(children: [span]));
  }
}

InlineSpan _htmlSpan(
  BuildContext context,
  String kind,
  String text,
  TextStyle base,
) {
  final scheme = Theme.of(context).colorScheme;
  final size = base.fontSize ?? 14;
  switch (kind) {
    case 'kbd':
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          constraints: const BoxConstraints(minWidth: 22),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Vb.radiusXs),
            border: Border(
              top: BorderSide(color: scheme.outline),
              left: BorderSide(color: scheme.outline),
              right: BorderSide(color: scheme.outline),
              bottom: BorderSide(color: scheme.outline, width: 2),
            ),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: base.copyWith(
              fontFamily: Vb.mono,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      );
    case 'mark':
      return TextSpan(
        text: text,
        style: base.copyWith(backgroundColor: context.vb.highlight),
      );
    case 'sub':
    case 'sup':
      return WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Transform.translate(
          offset: Offset(0, kind == 'sup' ? -size * 0.4 : size * 0.2),
          child: Text(text, style: base.copyWith(fontSize: size * 0.7)),
        ),
      );
    case 'u':
    case 'ins':
      return TextSpan(
        text: text,
        style: base.copyWith(decoration: TextDecoration.underline),
      );
    case 'small':
      return TextSpan(
        text: text,
        style: base.copyWith(fontSize: size * 0.85),
      );
  }
  return TextSpan(text: text);
}

/// 18 px task checkbox in the design's per-status style.
Widget _taskBox(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  final vb = context.vb;

  Widget box({Color? fill, Color? border, double bw = 1.5, Widget? child}) =>
      Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Vb.radiusXs),
          border: border == null ? null : Border.all(color: border, width: bw),
        ),
        child: child,
      );
  Widget glyph(IconData i, Color c) => Icon(i, size: 13, color: c);
  Widget letter(String t, Color c) => Text(
    t,
    style: TextStyle(
      fontSize: 12,
      height: 1,
      fontWeight: FontWeight.w700,
      color: c,
    ),
  );

  switch (status) {
    case 'x':
    case 'X':
      return box(
        fill: scheme.primary,
        child: glyph(LucideIcons.check, scheme.onPrimary),
      );
    case '/':
      return Container(
        width: 18,
        height: 18,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Vb.radiusXs),
          border: Border.all(color: scheme.primary, width: 1.5),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.5,
            heightFactor: 1,
            child: ColoredBox(color: scheme.primary),
          ),
        ),
      );
    case '-':
      return box(
        border: vb.inkFaint,
        child: glyph(LucideIcons.minus, scheme.onSurfaceVariant),
      );
    case '>':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.arrowRight, vb.warning),
      );
    case '<':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.calendar, vb.warning),
      );
    case '?':
      return box(border: vb.warning, child: letter('?', vb.warning));
    case '!':
      return box(fill: scheme.error, child: letter('!', scheme.surface));
    case '*':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.star, vb.warning),
      );
    case '"':
      return box(
        border: scheme.outline,
        child: glyph(LucideIcons.quote, scheme.onSurfaceVariant),
      );
    case 'i':
      return box(border: vb.info, child: glyph(LucideIcons.info, vb.info));
    case 'b':
      return box(border: vb.info, child: glyph(LucideIcons.bookmark, vb.info));
    case 'I':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.lightbulb, vb.warning),
      );
    case 'p':
      return box(
        border: vb.success,
        child: glyph(LucideIcons.thumbsUp, vb.success),
      );
    case 'c':
      return box(
        border: scheme.error,
        child: glyph(LucideIcons.thumbsDown, scheme.error),
      );
    case 'f':
      return box(
        border: vb.calloutWarning,
        child: glyph(LucideIcons.flame, vb.calloutWarning),
      );
    case 'k':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.keyRound, vb.warning),
      );
    case 'w':
      return box(
        border: vb.warning,
        child: glyph(LucideIcons.trophy, vb.warning),
      );
    case 'u':
      return box(
        border: vb.success,
        child: glyph(LucideIcons.trendingUp, vb.success),
      );
    case 'd':
      return box(
        border: scheme.error,
        child: glyph(LucideIcons.trendingDown, scheme.error),
      );
    default:
      return box(border: scheme.outline);
  }
}

Widget _image(
  BuildContext context,
  Uri uri,
  String? alt,
  ObsidianCallbacks callbacks,
) {
  // Obsidian syntax: ![alt|300](url) or ![alt|300x200](url)
  double? width;
  double? height;
  final size = RegExp(r'\|(\d+)(?:x(\d+))?$').firstMatch(alt ?? '');
  if (size != null) {
    width = double.parse(size[1]!);
    if (size[2] != null) height = double.parse(size[2]!);
  }
  final label = (alt ?? '').replaceFirst(RegExp(r'\|.*$'), '');
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    // Obsidian writes `![](Shared/assets/My%20photo.png)` when wikilinks are off: that is a
    // path in the vault, so look the file up among the attachments like `![[My photo.png]]`.
    final target = _vaultPath(uri);
    final embed = callbacks.embedBuilder?.call(context, target, width);
    return embed ?? _EmbedChip(target: target, onTap: callbacks.onWikiLink);
  }
  return Image.network(
    uri.toString(),
    width: width,
    height: height,
    errorBuilder: (context, error, stack) => Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Vb.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.imageOff, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label.isEmpty ? uri.host : label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The vault path a markdown link points at: percent-decoded, `<…>` brackets and a
/// leading `./` removed (`My%20photo.png` -> `My photo.png`).
String _vaultPath(Uri uri) {
  var path = uri.toString();
  if (path.startsWith('<') && path.endsWith('>')) {
    path = path.substring(1, path.length - 1);
  }
  try {
    path = Uri.decodeFull(path);
  } catch (_) {}
  return path.replaceFirst(RegExp(r'^\./'), '');
}

// ---------------------------------------------------------------- widgets

class TagPill extends StatelessWidget {
  const TagPill({
    super.key,
    required this.tag,
    this.onTap,
    this.compact = false,
    this.finder,
  });

  final NoteFinder? finder;
  final String tag;
  final void Function(String tag)? onTap;

  /// Inline in running text: 24 px tall instead of the 28 px properties pill.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap == null ? null : () => onTap!(tag),
      child: Container(
        height: compact ? 24 : Vb.chip,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(Vb.radiusPill),
        ),
        child: Center(
          widthFactor: 1,
          child: findText(
            finder,
            '#$tag',
            style: TextStyle(
              color: scheme.primary,
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmbedChip extends StatelessWidget {
  const _EmbedChip({required this.target, this.onTap, this.finder});

  final NoteFinder? finder;

  final String target;
  final void Function(String target)? onTap;

  static final _image = RegExp(
    r'\.(png|jpe?g|gif|webp|svg|bmp|avif)$',
    caseSensitive: false,
  );
  static final _audio = RegExp(
    r'\.(mp3|wav|m4a|ogg|flac|webm)$',
    caseSensitive: false,
  );
  static final _video = RegExp(r'\.(mp4|mov|mkv|ogv)$', caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = target.split('#').first;
    final icon = _image.hasMatch(file)
        ? LucideIcons.image
        : _audio.hasMatch(file)
        ? LucideIcons.music
        : _video.hasMatch(file)
        ? LucideIcons.film
        : file.toLowerCase().endsWith('.pdf')
        ? LucideIcons.fileText
        : LucideIcons.fileText;
    return InkWell(
      onTap: onTap == null ? null : () => onTap!(target),
      borderRadius: BorderRadius.circular(Vb.radiusSm),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Vb.radiusSm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              'Embedded:',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: findText(
                finder,
                target,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({
    super.key,
    required this.code,
    required this.language,
    this.finder,
  });

  final NoteFinder? finder;

  final String code;
  final String language;

  // Mermaid is drawn in the app (see MermaidBlock); these still need Obsidian's plugins.
  static const _pluginBlocks = {'query', 'dataview', 'dataviewjs', 'tasks'};

  @override
  Widget build(BuildContext context) {
    if (language.toLowerCase() == 'mermaid') return MermaidBlock(source: code);
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final reading = context.reading;
    final plugin = _pluginBlocks.contains(language.toLowerCase());

    final headerBorder = BorderSide(color: scheme.outlineVariant);
    final codeStyle = reading.code.copyWith(
      color: plugin ? scheme.onSurfaceVariant : scheme.onSurface,
    );

    return Container(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: vb.codeBg,
        borderRadius: BorderRadius.circular(Vb.radiusSm),
        border: Border.all(
          color: plugin ? scheme.outline : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: EdgeInsets.only(left: 12, right: plugin ? 12 : 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              border: Border(bottom: headerBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    (language.isEmpty ? 'text' : language).toUpperCase(),
                    style: reading.codeLabel.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (plugin)
                  Container(
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(Vb.radiusPill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.externalLink,
                          size: 12,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'RENDERS IN OBSIDIAN',
                          style: reading.codeLabel.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  TextButton.icon(
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
                    icon: const Icon(LucideIcons.copy, size: 14),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: findText(finder, code, style: codeStyle),
          ),
        ],
      ),
    );
  }
}

class _MathBlock extends StatelessWidget {
  const _MathBlock({required this.tex});
  final String tex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            tex,
            mathStyle: MathStyle.display,
            textStyle: Theme.of(
              context,
            ).textTheme.bodyLarge!.copyWith(fontSize: 20),
            onErrorFallback: (e) => Text(tex, style: context.reading.code),
          ),
        ),
      ),
    );
  }
}

class _Details extends StatefulWidget {
  const _Details({
    required this.summary,
    required this.initiallyOpen,
    required this.body,
    this.finder,
    this.bodyText = '',
  });
  final NoteFinder? finder;

  /// Raw markdown of the body, to open the section when the search matches inside it.
  final String bodyText;
  final String summary;
  final bool initiallyOpen;
  final Widget body;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                Expanded(
                  child: findText(
                    widget.finder,
                    widget.summary,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open || findHas(widget.finder, widget.bodyText))
          Padding(padding: const EdgeInsets.only(left: 24), child: widget.body),
      ],
    );
  }
}

class _Footnotes extends StatelessWidget {
  const _Footnotes({required this.section, this.finder});
  final md.Element section;
  final NoteFinder? finder;

  @override
  Widget build(BuildContext context) {
    final items =
        section.children
            ?.whereType<md.Element>()
            .where((e) => e.tag == 'ol')
            .expand((ol) => ol.children!.whereType<md.Element>())
            .toList() ??
        const <md.Element>[];
    final style = context.reading.small.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(
          height: 32,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}.',
                    style: style.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                Expanded(
                  child: findText(
                    finder,
                    items[i].textContent.replaceAll('↩', '').trim(),
                    style: style,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- styles

MarkdownStyleSheet obsidianStyleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final vb = context.vb;
  final r = context.reading;

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: r.body,
    h1: r.h1,
    h2: r.h2,
    h3: r.h3,
    h4: r.h3.copyWith(fontSize: 17),
    h5: r.h3.copyWith(fontSize: 16),
    h6: r.h3.copyWith(fontSize: 16, color: scheme.onSurfaceVariant),
    h1Padding: const EdgeInsets.only(top: Vb.space1, bottom: Vb.space1),
    h2Padding: const EdgeInsets.only(top: Vb.space1, bottom: Vb.space1),
    h3Padding: const EdgeInsets.only(top: Vb.space2, bottom: 2),
    blockSpacing: Vb.space3,
    a: r.body.copyWith(color: scheme.primary, fontWeight: FontWeight.w500),
    code: r.code.copyWith(backgroundColor: vb.codeBg, color: scheme.onSurface),
    // CodeBlock draws its own container.
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: scheme.outline, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
    blockquote: r.body.copyWith(
      color: scheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    ),
    tableBorder: TableBorder.all(
      color: scheme.outlineVariant,
      borderRadius: BorderRadius.circular(Vb.radiusSm),
    ),
    tableHead: r.small.copyWith(fontWeight: FontWeight.w600),
    tableBody: r.small,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    tableColumnWidth: const IntrinsicColumnWidth(flex: 1),
    tableHeadCellsDecoration: BoxDecoration(color: scheme.surfaceContainerHigh),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant)),
    ),
    listBullet: r.body,
    del: r.body.copyWith(
      decoration: TextDecoration.lineThrough,
      color: scheme.onSurfaceVariant,
    ),
  );
}
