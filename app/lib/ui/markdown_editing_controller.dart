import 'package:flutter/material.dart';

import '../markdown/callouts.dart';
import '../theme/vb_theme.dart';

/// Edit-tab controller that colours Obsidian syntax as you type: syntax marks in
/// ink-faint, wikilinks and tags in accent, headings bold, done tasks struck
/// through, `==highlight==` on the highlight colour. The text itself is never
/// altered, only styled, so offsets and the cursor behave normally.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  String _findQuery = '';
  int _findCurrent = -1;

  /// Case-insensitive matches of the find query in the text (empty when not searching).
  List<Match> findMatches() => _findQuery.isEmpty
      ? const []
      : RegExp(
          RegExp.escape(_findQuery),
          caseSensitive: false,
        ).allMatches(text).toList();

  /// Index of the selected match, or -1.
  int get findCurrent => _findCurrent;

  /// Highlights [query] in the text; [current] is drawn stronger.
  void setFind(String query, {int? current}) {
    _findQuery = query;
    final n = findMatches().length;
    _findCurrent = n == 0 ? -1 : (current ?? 0).clamp(0, n - 1);
    notifyListeners();
  }

  void clearFind() => setFind('');

  /// Moves the selected match by [by] (wrapping) and returns its range, or null.
  Match? stepFind(int by) {
    final all = findMatches();
    if (all.isEmpty) return null;
    final next =
        ((_findCurrent < 0 ? (by > 0 ? -1 : 0) : _findCurrent) + by) %
        all.length;
    _findCurrent = next < 0 ? next + all.length : next;
    notifyListeners();
    return all[_findCurrent];
  }

  Match? get currentFindMatch {
    final all = findMatches();
    return _findCurrent >= 0 && _findCurrent < all.length
        ? all[_findCurrent]
        : null;
  }

  /// Splits the already-styled [spans] so each find match gets a background.
  List<InlineSpan> _withFind(List<InlineSpan> spans, ColorScheme scheme) {
    final matches = findMatches();
    if (matches.isEmpty) return spans;
    final out = <InlineSpan>[];
    var offset = 0;
    var mi = 0;
    for (final sp in spans) {
      final t = (sp as TextSpan).text ?? '';
      final style = sp.style ?? const TextStyle();
      var pos = 0;
      while (pos < t.length) {
        final g = offset + pos;
        while (mi < matches.length && matches[mi].end <= g) {
          mi++;
        }
        if (mi < matches.length && matches[mi].start <= g) {
          final end = (matches[mi].end - offset).clamp(pos + 1, t.length);
          final selected = mi == _findCurrent;
          out.add(
            TextSpan(
              text: t.substring(pos, end),
              style: style.copyWith(
                backgroundColor: scheme.primary.withValues(
                  alpha: selected ? 0.5 : 0.22,
                ),
              ),
            ),
          );
          pos = end;
        } else {
          final next = mi < matches.length
              ? (matches[mi].start - offset).clamp(pos + 1, t.length)
              : t.length;
          out.add(TextSpan(text: t.substring(pos, next), style: style));
          pos = next;
        }
      }
      offset += t.length;
    }
    return out;
  }

  static final _heading = RegExp(r'^(#{1,6} )(.*)$');
  static final _task = RegExp(r'^(\s*(?:[-*+]|\d+\.) \[(.)\] )(.*)$');
  static final _quote = RegExp(r'^((?:>\s?)+)(\[![^\]]*\][+-]?)?(.*)$');
  static final _fm = RegExp(r'^([A-Za-z0-9_-]+:)(.*)$');
  static final _inline = RegExp(
    r'(\[\[[^\]\n]*\]\])|(==[^=\n]+==)|(`[^`\n]+`)|((?<![\w/&])#[\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)',
    unicode: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Leave the IME's own composing underline alone.
    if (withComposing &&
        value.isComposingRangeValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;
    final faint = base.copyWith(color: vb.inkFaint);
    final muted = base.copyWith(color: scheme.onSurfaceVariant);
    final accent = base.copyWith(color: scheme.primary);

    final spans = <InlineSpan>[];
    void add(String t, TextStyle s) {
      if (t.isNotEmpty) spans.add(TextSpan(text: t, style: s));
    }

    void inline(String t, TextStyle normal) {
      var at = 0;
      for (final m in _inline.allMatches(t)) {
        add(t.substring(at, m.start), normal);
        final tok = m[0]!;
        if (m[1] != null) {
          add('[[', faint);
          add(tok.substring(2, tok.length - 2), accent);
          add(']]', faint);
        } else if (m[2] != null) {
          add('==', faint);
          add(
            tok.substring(2, tok.length - 2),
            normal.copyWith(
              backgroundColor: vb.highlight,
              color: scheme.onSurface,
            ),
          );
          add('==', faint);
        } else if (m[3] != null) {
          add(tok, normal.copyWith(backgroundColor: vb.codeBg));
        } else {
          add(tok, accent);
        }
        at = m.end;
      }
      add(t.substring(at), normal);
    }

    final lines = text.split('\n');
    var inFrontmatter = false;
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i > 0) add('\n', base);

      if (i == 0 && line.trim() == '---') {
        inFrontmatter = true;
        add(line, faint);
        continue;
      }
      if (inFrontmatter) {
        if (line.trim() == '---') {
          inFrontmatter = false;
          add(line, faint);
        } else {
          final m = _fm.firstMatch(line);
          if (m != null) {
            add(m[1]!, muted);
            add(m[2]!, base);
          } else {
            add(line, base);
          }
        }
        continue;
      }
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        add(line, faint);
        continue;
      }
      if (inFence) {
        add(line, muted);
        continue;
      }

      final h = _heading.firstMatch(line);
      if (h != null) {
        add(h[1]!, faint.copyWith(fontWeight: FontWeight.w600));
        inline(h[2]!, base.copyWith(fontWeight: FontWeight.w600));
        continue;
      }
      final t = _task.firstMatch(line);
      if (t != null) {
        add(t[1]!, faint);
        final done = t[2] == 'x' || t[2] == 'X';
        if (done) {
          add(
            t[3]!,
            muted.copyWith(
              decoration: TextDecoration.lineThrough,
              decorationColor: scheme.onSurfaceVariant,
            ),
          );
        } else {
          inline(t[3]!, base);
        }
        continue;
      }
      final q = _quote.firstMatch(line);
      if (q != null && q[1]!.isNotEmpty) {
        add(q[1]!, faint);
        if (q[2] != null) {
          final type = RegExp(
            r'\[!([^\]]*)\]',
          ).firstMatch(q[2]!)![1]!.toLowerCase();
          add(
            q[2]!,
            base.copyWith(color: calloutStyleFor(type).colorIn(context)),
          );
        }
        inline(q[3]!, base);
        continue;
      }
      inline(line, base);
    }
    return TextSpan(style: base, children: _withFind(spans, scheme));
  }
}
