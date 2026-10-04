import 'package:markdown/markdown.dart' as md;

/// Parser extensions that teach the `markdown` package Obsidian's syntax.
///
/// Each syntax emits an element with an `obs-*` tag; the matching widget is
/// built in `obsidian_builders.dart`. Block syntaxes that contain markdown
/// (callouts, details) keep their inner source in the `body` attribute and are
/// rendered recursively, because flutter_markdown builders can't receive
/// already-built child widgets.

List<md.BlockSyntax> obsidianBlockSyntaxes() => const [
  EmbedBlockSyntax(),
  CalloutSyntax(),
  MathBlockSyntax(),
  CommentBlockSyntax(),
  DetailsSyntax(),
  md.FootnoteDefSyntax(),
];

List<md.InlineSyntax> obsidianInlineSyntaxes() => [
  CommentInlineSyntax(),
  EmbedSyntax(),
  WikiLinkSyntax(),
  InlineFootnoteSyntax(),
  BlockIdSyntax(),
  HighlightSyntax(),
  TagSyntax(),
  InlineMathSyntax(),
  HtmlInlineSyntax(),
  LineBreakHtmlSyntax(),
  SpanHtmlSyntax(),
  AltTaskStatusSyntax(),
];

// ---------------------------------------------------------------- blocks

/// `> [!type]+/- Optional title` followed by `>` lines. Nesting works because
/// the body is parsed again with the same syntaxes.
class CalloutSyntax extends md.BlockSyntax {
  const CalloutSyntax();

  static final _start = RegExp(r'^ {0,3}>\s?\[!([^\]\s]+)\]([+-]?)\s*(.*)$');
  static final _quote = RegExp(r'^ {0,3}>');
  static final _strip = RegExp(r'^ {0,3}> ?');

  @override
  RegExp get pattern => _start;

  @override
  md.Node? parse(md.BlockParser parser) {
    final first = _start.firstMatch(parser.current.content)!;
    parser.advance();
    final body = <String>[];
    while (!parser.isDone && _quote.hasMatch(parser.current.content)) {
      body.add(parser.current.content.replaceFirst(_strip, ''));
      parser.advance();
    }
    return md.Element.empty('obs-callout')
      ..attributes['type'] = first[1]!.toLowerCase()
      ..attributes['fold'] = first[2]!
      ..attributes['title'] = first[3]!.trim()
      ..attributes['body'] = body.join('\n');
  }
}

/// `$$ ... $$` (single or multiple lines).
class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();

  static final _start = RegExp(r'^\s*\$\$');

  @override
  RegExp get pattern => _start;

  @override
  md.Node? parse(md.BlockParser parser) {
    final buffer = StringBuffer();
    var line = parser.current.content.trimLeft().substring(2);
    parser.advance();
    // Single line: $$ x $$
    if (line.trimRight().endsWith(r'$$')) {
      buffer.write(line.trimRight().substring(0, line.trimRight().length - 2));
    } else {
      buffer.writeln(line);
      while (!parser.isDone) {
        line = parser.current.content;
        parser.advance();
        final trimmed = line.trimRight();
        if (trimmed.endsWith(r'$$')) {
          buffer.write(trimmed.substring(0, trimmed.length - 2));
          break;
        }
        buffer.writeln(line);
      }
    }
    return md.Element.empty('obs-math-block')
      ..attributes['tex'] = buffer.toString().trim();
  }
}

/// A `%%` line opens a multi-line comment that is hidden until the next `%%`.
class CommentBlockSyntax extends md.BlockSyntax {
  const CommentBlockSyntax();

  static final _start = RegExp(r'^\s*%%\s*$');

  @override
  RegExp get pattern => _start;

  @override
  md.Node? parse(md.BlockParser parser) {
    parser.advance();
    while (!parser.isDone) {
      final end = parser.current.content.trimRight().endsWith('%%');
      parser.advance();
      if (end) break;
    }
    return null;
  }
}

/// `<details><summary>Title</summary> ... </details>`
class DetailsSyntax extends md.BlockSyntax {
  const DetailsSyntax();

  static final _start = RegExp(r'^\s*<details\b[^>]*>', caseSensitive: false);
  static final _end = RegExp(r'</details>', caseSensitive: false);
  static final _summary = RegExp(
    r'<summary>([\s\S]*?)</summary>',
    caseSensitive: false,
  );

  @override
  RegExp get pattern => _start;

  @override
  md.Node? parse(md.BlockParser parser) {
    final lines = <String>[];
    final open = parser.current.content.toLowerCase().contains('<details open');
    while (!parser.isDone) {
      final line = parser.current.content;
      lines.add(line);
      parser.advance();
      if (_end.hasMatch(line)) break;
    }
    var text = lines.join('\n').replaceFirst(_start, '').replaceFirst(_end, '');
    final summary = _summary.firstMatch(text);
    text = text.replaceFirst(_summary, '');
    return md.Element.empty('obs-details')
      ..attributes['summary'] = summary?[1]?.trim() ?? 'Details'
      ..attributes['open'] = open ? 'true' : 'false'
      ..attributes['body'] = text.trim();
  }
}

// ---------------------------------------------------------------- inline

/// `%%hidden%%` on one line.
class CommentInlineSyntax extends md.InlineSyntax {
  CommentInlineSyntax() : super(r'%%[^\n]*?%%', startCharacter: 0x25);

  @override
  bool onMatch(md.InlineParser parser, Match match) => true; // emit nothing
}

/// A line that is only `![[target]]` or `![[image.png|300]]` is a block, like Obsidian's
/// reading view: pictures get their own row instead of sitting inside a text line, where a
/// tall inline widget would overlap its neighbours. Embeds inside a sentence stay inline.
class EmbedBlockSyntax extends md.BlockSyntax {
  const EmbedBlockSyntax();

  static final _line = RegExp(r'^\s{0,3}!\[\[([^\]\n]+)\]\]\s*$');

  @override
  RegExp get pattern => _line;

  @override
  md.Node? parse(md.BlockParser parser) {
    final match = _line.firstMatch(parser.current.content)!;
    parser.advance();
    final parts = match[1]!.split('|');
    return md.Element.empty('obs-embed-block')
      ..attributes['target'] = parts.first.trim()
      ..attributes['size'] = parts.length > 1 ? parts[1].trim() : '';
  }
}

/// `![[target]]`, `![[image.png|300]]`
class EmbedSyntax extends md.InlineSyntax {
  EmbedSyntax() : super(r'!\[\[([^\]\n]+)\]\]', startCharacter: 0x21);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final parts = match[1]!.split('|');
    parser.addNode(
      md.Element.empty('obs-embed')
        ..attributes['target'] = parts.first.trim()
        ..attributes['size'] = parts.length > 1 ? parts[1].trim() : '',
    );
    return true;
  }
}

/// `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, `[[#Heading]]`, `[[Note#^block]]`
class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax() : super(r'\[\[([^\]\n]+)\]\]', startCharacter: 0x5B);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[1]!;
    final pipe = raw.indexOf('|');
    final target = (pipe >= 0 ? raw.substring(0, pipe) : raw).trim();
    final alias = pipe >= 0 ? raw.substring(pipe + 1).trim() : null;
    parser.addNode(
      md.Element.text('obs-wikilink', alias ?? displayForTarget(target))
        ..attributes['target'] = target,
    );
    return true;
  }

  /// `Note#Heading` → `Note > Heading`, `#Heading` → `Heading`, `Note#^id` → `Note`
  static String displayForTarget(String target) {
    final hash = target.indexOf('#');
    if (hash < 0) return target;
    final note = target.substring(0, hash);
    final sub = target.substring(hash + 1);
    if (sub.startsWith('^')) return note.isEmpty ? sub : note;
    return note.isEmpty ? sub : '$note > $sub';
  }
}

/// `^[inline footnote]`
class InlineFootnoteSyntax extends md.InlineSyntax {
  InlineFootnoteSyntax() : super(r'\^\[([^\]\n]+)\]', startCharacter: 0x5E);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('obs-inline-fn', match[1]!));
    return true;
  }
}

/// Trailing ` ^block-id` markers are hidden, as in Obsidian's reading view.
class BlockIdSyntax extends md.InlineSyntax {
  BlockIdSyntax() : super(r'[ \t]+\^[A-Za-z0-9-]+[ \t]*$');

  @override
  bool onMatch(md.InlineParser parser, Match match) => true;
}

/// `==highlight==`
class HighlightSyntax extends md.InlineSyntax {
  HighlightSyntax() : super(r'==(?=\S)([^\n]*?\S)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('obs-mark', match[1]!));
    return true;
  }
}

/// `#tag`, `#nested/tag`. Must not start with a digit, and must not follow a
/// word character (so `C#` or URLs with fragments are not tags).
class TagSyntax extends md.InlineSyntax {
  TagSyntax()
    : super(
        r'(?<![A-Za-z0-9_&/#À-￿])#([A-Za-z_À-￿][A-Za-z0-9_/\-À-￿]*)',
        startCharacter: 0x23,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('obs-tag', match[1]!));
    return true;
  }
}

/// `$inline math$` (no space just inside the dollars, not followed by a digit).
class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax()
    : super(r'\$(?=[^\s$])([^$\n]*?[^\s\\$])\$(?!\d)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.empty('obs-math-inline')..attributes['tex'] = match[1]!,
    );
    return true;
  }
}

/// `<kbd>`, `<mark>`, `<sub>`, `<sup>`, `<u>`, `<ins>`, `<small>`
class HtmlInlineSyntax extends md.InlineSyntax {
  HtmlInlineSyntax()
    : super(
        r'<(kbd|mark|sub|sup|u|ins|small)>([^<\n]*)</\1>',
        startCharacter: 0x3C,
        caseSensitive: false,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text('obs-html', match[2]!)
        ..attributes['kind'] = match[1]!.toLowerCase(),
    );
    return true;
  }
}

class LineBreakHtmlSyntax extends md.InlineSyntax {
  LineBreakHtmlSyntax()
    : super(r'<br\s*/?>', startCharacter: 0x3C, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// `<span ...>text</span>`: keep the text, drop the tag.
class SpanHtmlSyntax extends md.InlineSyntax {
  SpanHtmlSyntax()
    : super(
        r'<span\b[^>]*>([^<\n]*)</span>',
        startCharacter: 0x3C,
        caseSensitive: false,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Text(match[1]!));
    return true;
  }
}

/// Obsidian/theme task statuses beyond `[ ]` and `[x]`: `- [/]`, `- [-]`, `- [>]`, ...
/// Only matches at the very start of a list item's text.
class AltTaskStatusSyntax extends md.InlineSyntax {
  AltTaskStatusSyntax()
    : super(r'(?<![\s\S])\[([^\]xX ])\][ \t]', startCharacter: 0x5B);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // type=checkbox makes the list item draw a checkbox instead of a bullet; the
    // status itself is drawn by the checkbox builder.
    parser.addNode(
      md.Element.empty('obs-task')
        ..attributes['status'] = match[1]!
        ..attributes['type'] = 'checkbox',
    );
    return true;
  }
}
