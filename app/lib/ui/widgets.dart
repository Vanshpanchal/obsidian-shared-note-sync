import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/shared_repository.dart';
import '../theme/vb_theme.dart';

/// The VaultBridge mark: an arch with two end dots.
class VbMark extends StatelessWidget {
  const VbMark({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MarkPainter(color ?? Theme.of(context).colorScheme.primary),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 48;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * k
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(10 * k, 32 * k)
      ..cubicTo(10 * k, 14 * k, 38 * k, 14 * k, 38 * k, 32 * k);
    canvas.drawPath(path, stroke);
    final fill = Paint()..color = color;
    canvas.drawCircle(Offset(10 * k, 32 * k), 5.5 * k, fill);
    canvas.drawCircle(Offset(38 * k, 32 * k), 5.5 * k, fill);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// Sync status pill shown in the app bar. 28 px pill, 48 px hit area.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.status,
    this.onTap,
    this.pendingCount = 0,
    this.loading = false,
  });

  final SyncStatus status;
  final VoidCallback? onTap;
  final int pendingCount;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vb = context.vb;

    final (
      String label,
      IconData? icon,
      Color bg,
      Color fg,
      Color? bd,
      bool spin,
    ) = loading
        ? ('Loading', null, Colors.transparent, vb.info, null, true)
        : switch (status) {
            SyncStatus.saved => (
              'Saved',
              LucideIcons.cloudCheck,
              Colors.transparent,
              scheme.onSurfaceVariant,
              null,
              false,
            ),
            SyncStatus.pending => (
              'Unsaved',
              LucideIcons.pencilLine,
              scheme.surfaceContainerHigh,
              scheme.onSurfaceVariant,
              scheme.outlineVariant,
              false,
            ),
            SyncStatus.saving => (
              'Saving',
              null,
              Colors.transparent,
              vb.info,
              null,
              true,
            ),
            SyncStatus.offline => (
              'Offline',
              LucideIcons.cloudOff,
              vb.warningContainer,
              vb.warning,
              null,
              false,
            ),
            SyncStatus.conflict => (
              'Conflict',
              LucideIcons.triangleAlert,
              scheme.errorContainer,
              scheme.error,
              scheme.error.withValues(alpha: 0.4),
              false,
            ),
            SyncStatus.error => (
              'Sync error',
              LucideIcons.circleAlert,
              scheme.errorContainer,
              scheme.error,
              null,
              false,
            ),
            SyncStatus.notConfigured => (
              'Set up',
              LucideIcons.settings,
              scheme.primaryContainer,
              scheme.primary,
              null,
              false,
            ),
          };

    final iconColor = !loading && status == SyncStatus.saved ? vb.success : fg;
    final tip = loading
        ? 'Fetching shared.md…'
        : switch (status) {
            SyncStatus.saved => 'Saved · server and this phone match.',
            SyncStatus.pending => 'Unsaved · saves itself after 2 s idle.',
            SyncStatus.saving => 'Saving…',
            SyncStatus.offline =>
              'Offline – will retry. Your edits are safe on this phone.',
            SyncStatus.conflict => 'Conflict · tap to resolve.',
            SyncStatus.error =>
              'Couldn’t sync. Your edits are safe on this phone.',
            SyncStatus.notConfigured => 'Not set up · tap to connect.',
          };

    final showBadge =
        status == SyncStatus.offline && pendingCount > 0 && !loading;

    return Semantics(
      button: true,
      label: 'Sync status: $label',
      child: Tooltip(
        message: tip,
        triggerMode: TooltipTriggerMode.longPress,
        child: InkResponse(
          onTap: onTap,
          radius: 28,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Vb.touch),
            child: Center(
              child: Container(
                height: Vb.chip,
                padding: const EdgeInsets.only(left: 8, right: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(Vb.radiusPill),
                  border: bd == null ? null : Border.all(color: bd),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (spin)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg,
                        ),
                      )
                    else
                      Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: Vb.space1 + 2),
                    Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge!.copyWith(color: fg),
                    ),
                    if (showBadge) ...[
                      const SizedBox(width: 6),
                      Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        height: 16,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: vb.warning,
                          borderRadius: BorderRadius.circular(Vb.radiusPill),
                        ),
                        child: Text(
                          '$pendingCount',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            color: scheme.surface,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped segmented control (Edit / Preview, theme, editor font).
class VbSegmented<T> extends StatelessWidget {
  const VbSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.semanticLabel,
    this.height = 40,
  });

  final T value;
  final List<VbSegment<T>> options;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Vb.radiusPill),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0)
                VerticalDivider(width: 1, thickness: 1, color: scheme.outline),
              Expanded(child: _cell(context, options[i])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, VbSegment<T> o) {
    final scheme = Theme.of(context).colorScheme;
    final selected = o.value == value;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(o.value),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (o.icon != null && selected) ...[
                  Icon(o.icon, size: 16, color: color),
                  const SizedBox(width: 6),
                ],
                Text(
                  o.label,
                  style: (o.style ?? Theme.of(context).textTheme.labelLarge!)
                      .copyWith(
                        color: color,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class VbSegment<T> {
  const VbSegment(this.value, this.label, {this.icon, this.style});
  final T value;
  final String label;
  final IconData? icon;
  final TextStyle? style;
}

/// Round icon badge used at the top of sheets and dialogs.
class VbIconCircle extends StatelessWidget {
  const VbIconCircle({
    super.key,
    required this.icon,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: background, shape: BoxShape.circle),
    child: Icon(icon, size: 22, color: color),
  );
}

/// Bordered rounded group of rows (settings, status sheet).
class VbGroup extends StatelessWidget {
  const VbGroup({super.key, required this.children, this.color});

  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Rounded search field used for "Search files" and "Find in note": a tinted pill that
/// gets an accent ring while focused, a clear button once there is text, and an optional
/// [trailing] widget (e.g. a match counter) inside the field.
class VbSearchField extends StatefulWidget {
  const VbSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.trailing,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final Widget? trailing;
  final bool autofocus;

  @override
  State<VbSearchField> createState() => _VbSearchFieldState();
}

class _VbSearchFieldState extends State<VbSearchField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final focused = widget.focusNode.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;
    return TextFieldTapRegion(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Vb.radiusLg),
          border: Border.all(
            color: focused ? scheme.primary : scheme.outlineVariant,
            width: focused ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Icon(
                LucideIcons.search,
                size: 18,
                color: focused ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                textInputAction: TextInputAction.search,
                // Tap anywhere else (the note, the list, the tabs) to drop focus and the keyboard.
                onTapOutside: (_) => widget.focusNode.unfocus(),
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                cursorColor: scheme.primary,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: widget.hint,
                  hintStyle: theme.textTheme.bodyLarge!.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
            if (hasText)
              Semantics(
                button: true,
                label: 'Clear search',
                child: InkResponse(
                  onTap: () {
                    widget.controller.clear();
                    widget.onChanged('');
                    widget.onClear?.call();
                    widget.focusNode.requestFocus();
                  },
                  radius: 18,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Icon(
                      LucideIcons.circleX,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
