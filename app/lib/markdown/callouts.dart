import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/vb_theme.dart';

/// Semantic colour of a callout, resolved against the theme's tokens.
enum CalloutRole {
  note,
  abstract,
  success,
  question,
  warning,
  danger,
  example,
  quote,
}

/// Visual style for one Obsidian callout type.
class CalloutStyle {
  const CalloutStyle(this.role, this.icon, this.label);
  final CalloutRole role;
  final IconData icon;
  final String label;

  /// Dark-theme colour; use [colorIn] for the live theme.
  Color get color => _resolve(
    role,
    VbColors.dark,
    const Color(0xFFA48BFA),
    const Color(0xFFA3A1AD),
    const Color(0xFFF07A7A),
  );

  Color colorIn(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _resolve(
      role,
      context.vb,
      scheme.primary,
      scheme.onSurfaceVariant,
      scheme.error,
    );
  }

  static Color _resolve(
    CalloutRole r,
    VbColors vb,
    Color accent,
    Color muted,
    Color danger,
  ) => switch (r) {
    CalloutRole.note => vb.info,
    CalloutRole.abstract => vb.calloutAbstract,
    CalloutRole.success => vb.success,
    CalloutRole.question => vb.warning,
    CalloutRole.warning => vb.calloutWarning,
    CalloutRole.danger => danger,
    CalloutRole.example => accent,
    CalloutRole.quote => muted,
  };
}

const Map<String, CalloutStyle> _base = {
  'note': CalloutStyle(CalloutRole.note, LucideIcons.pencil, 'Note'),
  'abstract': CalloutStyle(CalloutRole.abstract, LucideIcons.flame, 'Abstract'),
  'info': CalloutStyle(CalloutRole.note, LucideIcons.pencil, 'Info'),
  'todo': CalloutStyle(CalloutRole.note, LucideIcons.pencil, 'Todo'),
  'tip': CalloutStyle(CalloutRole.abstract, LucideIcons.flame, 'Tip'),
  'success': CalloutStyle(CalloutRole.success, LucideIcons.check, 'Success'),
  'question': CalloutStyle(
    CalloutRole.question,
    LucideIcons.circleQuestionMark,
    'Question',
  ),
  'warning': CalloutStyle(
    CalloutRole.warning,
    LucideIcons.triangleAlert,
    'Warning',
  ),
  'failure': CalloutStyle(CalloutRole.danger, LucideIcons.zap, 'Failure'),
  'danger': CalloutStyle(CalloutRole.danger, LucideIcons.zap, 'Danger'),
  'bug': CalloutStyle(CalloutRole.danger, LucideIcons.zap, 'Bug'),
  'example': CalloutStyle(CalloutRole.example, LucideIcons.list, 'Example'),
  'quote': CalloutStyle(CalloutRole.quote, LucideIcons.quote, 'Quote'),
};

const Map<String, String> _aliases = {
  'summary': 'abstract',
  'tldr': 'abstract',
  'hint': 'tip',
  'important': 'tip',
  'check': 'success',
  'done': 'success',
  'help': 'question',
  'faq': 'question',
  'caution': 'warning',
  'attention': 'warning',
  'fail': 'failure',
  'missing': 'failure',
  'error': 'danger',
  'cite': 'quote',
};

/// Unknown types fall back to the note style, as in Obsidian. The default
/// title is the type name as written, capitalized (e.g. `[!faq]` → "Faq").
CalloutStyle calloutStyleFor(String type) {
  final base = _base[_aliases[type] ?? type] ?? _base['note']!;
  final label = type.isEmpty
      ? base.label
      : '${type[0].toUpperCase()}${type.substring(1)}';
  return CalloutStyle(base.role, base.icon, label);
}

class CalloutBox extends StatefulWidget {
  const CalloutBox({
    super.key,
    required this.type,
    required this.title,
    required this.fold,
    required this.bodyBuilder,
    required this.titleBuilder,
  });

  final String type;
  final String title;

  /// '' (not foldable), '+' (open), '-' (closed)
  final String fold;
  final Widget Function(BuildContext) bodyBuilder;
  final Widget Function(BuildContext, String title, TextStyle style)
  titleBuilder;

  @override
  State<CalloutBox> createState() => _CalloutBoxState();
}

class _CalloutBoxState extends State<CalloutBox> {
  late bool _open = widget.fold != '-';

  @override
  Widget build(BuildContext context) {
    final style = calloutStyleFor(widget.type);
    final color = style.colorIn(context);
    final bg = Theme.of(context).colorScheme.surface;
    final isQuote = style.role == CalloutRole.quote;
    final foldable = widget.fold.isNotEmpty;
    // A callout inside a callout is a little tighter: radius 8, padding 10/12, fill 12%.
    final nested = _CalloutDepth.of(context);
    final titleStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: color,
      fontSize: 15,
      height: 22 / 15,
      fontWeight: FontWeight.w600,
    );

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(style.icon, size: 18, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: widget.titleBuilder(
            context,
            widget.title.isEmpty ? style.label : widget.title,
            titleStyle,
          ),
        ),
        if (foldable)
          AnimatedRotation(
            turns: _open ? 0.25 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(LucideIcons.chevronRight, size: 18, color: color),
          ),
      ],
    );

    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: isQuote ? 0.08 : (nested ? 0.12 : 0.10)),
          bg,
        ),
        borderRadius: BorderRadius.circular(nested ? 8 : Vb.radiusMd),
        border: Border.all(
          color: color.withValues(alpha: isQuote ? 0.26 : 0.30),
        ),
      ),
      padding: nested
          ? const EdgeInsets.fromLTRB(12, 10, 12, 10)
          : const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (foldable)
            InkWell(onTap: () => setState(() => _open = !_open), child: header)
          else
            header,
          if (_open)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _CalloutDepth(child: Builder(builder: widget.bodyBuilder)),
            ),
        ],
      ),
    );
  }
}

/// Marks the subtree as being inside a callout so nested ones render tighter.
class _CalloutDepth extends InheritedWidget {
  const _CalloutDepth({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CalloutDepth>() != null;

  @override
  bool updateShouldNotify(_CalloutDepth old) => false;
}
