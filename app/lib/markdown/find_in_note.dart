import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

/// Find-in-note state for the preview: the query, the highlighted matches that are
/// currently on screen, and which one is selected.
///
/// Matches are found in the rendered text (an inline syntax turns each hit into an
/// `obs-find` node), so the count is what you can actually see and never includes
/// markdown syntax such as link URLs. Each match registers itself here when it is
/// built; after the frame they are sorted top-to-bottom to give next/previous order.
class NoteFinder extends ChangeNotifier {
  /// Changes only when the query text does; the preview rebuilds on this.
  final query = ValueNotifier<String>('');

  final _matches = <FindMatchState>[];
  List<FindMatchState> _ordered = const [];
  int _current = -1;
  bool _pending = false;
  bool _revealNext = false;

  bool get _hasCurrent => _current >= 0 && _current < _ordered.length;

  bool get active => query.value.isNotEmpty;

  /// Number of matches in the note.
  int get count => _ordered.length;

  /// Zero-based index of the selected match, or -1.
  int get current => _current;

  bool isCurrent(FindMatchState m) =>
      _current >= 0 && _current < count && _ordered[_current] == m;

  void setQuery(String value) {
    final q = value.trim();
    if (q == query.value) return;
    _current = -1;
    _revealNext = true; // jump to the first hit once the new matches are built
    query.value = q;
    notifyListeners();
  }

  void clear() {
    _revealNext = false;
    setQuery('');
  }

  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int by) {
    if (count == 0) return;
    _current = _current < 0
        ? (by > 0 ? 0 : count - 1)
        : (_current + by) % count;
    if (_current < 0) _current += count;
    notifyListeners();
    _reveal();
  }

  void _reveal() {
    if (_current < 0 || _current >= count) return;
    final ctx = _ordered[_current].context;
    if (!ctx.mounted) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _register(FindMatchState m) {
    _matches.add(m);
    _schedule();
  }

  void _unregister(FindMatchState m) {
    _matches.remove(m);
    _schedule();
  }

  void _schedule() {
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      _resort();
    });
  }

  void _resort() {
    final keep = _hasCurrent ? _ordered[_current] : null;
    final withPos = <(FindMatchState, Offset)>[];
    for (final m in _matches) {
      final box = m.context.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        withPos.add((m, box.localToGlobal(Offset.zero)));
      }
    }
    withPos.sort((a, b) {
      // Same line (within half a line) -> left to right.
      final dy = a.$2.dy - b.$2.dy;
      return dy.abs() < 6 ? a.$2.dx.compareTo(b.$2.dx) : dy.compareTo(0);
    });
    _ordered = [for (final e in withPos) e.$1];

    if (keep != null && _ordered.contains(keep)) {
      _current = _ordered.indexOf(keep);
    } else if (_ordered.isEmpty) {
      _current = -1;
    } else if (_current < 0 || _current >= _ordered.length) {
      _current = 0;
    }
    notifyListeners();
    if (_revealNext && _ordered.isNotEmpty) {
      _revealNext = false;
      _reveal();
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }
}

/// Turns every case-insensitive occurrence of [query] in plain text into an
/// `obs-find` element.
class FindSyntax extends md.InlineSyntax {
  FindSyntax(String query) : super(RegExp.escape(query), caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('obs-find', match[0]!));
    return true;
  }
}

/// One highlighted hit. Registers with [finder] so it can be counted, ordered and
/// scrolled to, and repaints when the selection moves.
class FindMatch extends StatefulWidget {
  const FindMatch({
    super.key,
    required this.finder,
    required this.text,
    required this.style,
  });

  final NoteFinder finder;
  final String text;
  final TextStyle style;

  @override
  State<FindMatch> createState() => FindMatchState();
}

class FindMatchState extends State<FindMatch> {
  @override
  void initState() {
    super.initState();
    widget.finder._register(this);
    widget.finder.addListener(_changed);
  }

  @override
  void dispose() {
    widget.finder.removeListener(_changed);
    widget.finder._unregister(this);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.finder.isCurrent(this);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: 0.55)
            : scheme.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        widget.text,
        style: widget.style.copyWith(
          color: selected ? scheme.onPrimary : widget.style.color,
          fontWeight: selected ? FontWeight.w700 : widget.style.fontWeight,
        ),
      ),
    );
  }
}

/// [text] as a span with every match of the search query turned into a [FindMatch],
/// so text outside the normal paragraph flow (links, tags, code, properties…) is
/// highlighted, counted and scrolled to like the rest. Plain when not searching.
/// [onTap] keeps tapping a highlighted part working (e.g. inside a wikilink).
InlineSpan findSpan(
  NoteFinder? finder,
  String text,
  TextStyle style, {
  GestureRecognizer? recognizer,
  VoidCallback? onTap,
}) {
  final q = finder?.query.value ?? '';
  if (finder == null || q.isEmpty) {
    return TextSpan(text: text, style: style, recognizer: recognizer);
  }
  final children = <InlineSpan>[];
  var at = 0;
  for (final m in RegExp(
    RegExp.escape(q),
    caseSensitive: false,
  ).allMatches(text)) {
    if (m.start > at) {
      children.add(
        TextSpan(text: text.substring(at, m.start), recognizer: recognizer),
      );
    }
    Widget hit = FindMatch(finder: finder, text: m[0]!, style: style);
    if (onTap != null) hit = GestureDetector(onTap: onTap, child: hit);
    children.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: hit,
      ),
    );
    at = m.end;
  }
  if (children.isEmpty)
    return TextSpan(text: text, style: style, recognizer: recognizer);
  if (at < text.length) {
    children.add(
      TextSpan(text: text.substring(at), style: style, recognizer: recognizer),
    );
  }
  // Flat and style-less on purpose: flutter_markdown merges only one level of spans,
  // so every child carries its own style.
  return TextSpan(children: children);
}

/// A [Text] that highlights the search query; a normal [Text] when not searching.
Widget findText(
  NoteFinder? finder,
  String text, {
  TextStyle? style,
  int? maxLines,
  TextOverflow? overflow,
  TextAlign? textAlign,
}) {
  if (finder == null || finder.query.value.isEmpty) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
  return Text.rich(
    findSpan(finder, text, style ?? const TextStyle()),
    maxLines: maxLines,
    overflow: overflow,
    textAlign: textAlign,
  );
}

/// True when [text] contains the current query (case-insensitive).
bool findHas(NoteFinder? finder, String text) {
  final q = finder?.query.value ?? '';
  return q.isNotEmpty && text.toLowerCase().contains(q.toLowerCase());
}
