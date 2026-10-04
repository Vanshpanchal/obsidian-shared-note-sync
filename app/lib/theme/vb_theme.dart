import 'package:flutter/material.dart';

/// VaultBridge design tokens. Names map 1:1 to the design's token sheet
/// (bg, surface, surface-raised, ink, accent, ...). Two hand-tuned palettes:
/// don't seed from one colour, the contrast pairs would be lost.
@immutable
class VbColors extends ThemeExtension<VbColors> {
  const VbColors({
    required this.codeBg,
    required this.inkFaint,
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.info,
    required this.infoContainer,
    required this.highlight,
    required this.calloutAbstract,
    required this.calloutWarning,
    required this.scrim,
    required this.shadowSheet,
    required this.shadowFab,
    required this.skeleton,
    required this.skeletonStrong,
  });

  final Color codeBg;
  final Color inkFaint;
  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color info;
  final Color infoContainer;
  final Color highlight;
  final Color calloutAbstract;
  final Color calloutWarning;
  final Color scrim;
  final Color shadowSheet;
  final Color shadowFab;
  final Color skeleton;
  final Color skeletonStrong;

  static const dark = VbColors(
    codeBg: Color(0xFF111016),
    inkFaint: Color(0xFF75737F),
    success: Color(0xFF5FCF8F),
    successContainer: Color(0xFF15291E),
    warning: Color(0xFFE8B25A),
    warningContainer: Color(0xFF2E2412),
    info: Color(0xFF6AA9F0),
    infoContainer: Color(0xFF152237),
    highlight: Color(0xFF4D4214),
    calloutAbstract: Color(0xFF4CC7B6),
    calloutWarning: Color(0xFFF0A050),
    scrim: Color(0xA808070C),
    shadowSheet: Color(0x73000000),
    shadowFab: Color(0x80000000),
    skeleton: Color(0xFF25242D),
    skeletonStrong: Color(0xFF34323D),
  );

  static const light = VbColors(
    codeBg: Color(0xFFF4F2EF),
    inkFaint: Color(0xFF8A8794),
    success: Color(0xFF17703F),
    successContainer: Color(0xFFE5F4EA),
    warning: Color(0xFF8A5600),
    warningContainer: Color(0xFFFBF0DC),
    info: Color(0xFF1F5BBF),
    infoContainer: Color(0xFFE4EEFC),
    highlight: Color(0xFFFDF0A6),
    calloutAbstract: Color(0xFF0D7568),
    calloutWarning: Color(0xFFA04A00),
    scrim: Color(0x6B1D1B22),
    shadowSheet: Color(0x1A1D1B22),
    shadowFab: Color(0x406246D6),
    skeleton: Color(0xFFF3F1EE),
    skeletonStrong: Color(0xFFE4E1DC),
  );

  @override
  VbColors copyWith() => this;

  @override
  VbColors lerp(VbColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

/// Reading-view and editor type styles (md-*, editor, code, code-label).
@immutable
class VbReading extends ThemeExtension<VbReading> {
  const VbReading({
    required this.h1,
    required this.h2,
    required this.h3,
    required this.body,
    required this.small,
    required this.editor,
    required this.code,
    required this.codeLabel,
  });

  final TextStyle h1;
  final TextStyle h2;
  final TextStyle h3;
  final TextStyle body;
  final TextStyle small;
  final TextStyle editor;
  final TextStyle code;
  final TextStyle codeLabel;

  @override
  VbReading copyWith() => this;

  @override
  VbReading lerp(VbReading? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Layout constants (spacing, radius, size tokens).
class Vb {
  Vb._();

  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space5 = 20.0;
  static const space6 = 24.0;
  static const space8 = 32.0;
  static const space10 = 40.0;

  static const radiusXs = 4.0;
  static const radiusSm = 6.0;
  static const radiusMd = 10.0;
  static const radiusLg = 16.0;
  static const radiusXl = 24.0;
  static const radiusPill = 999.0;

  static const touch = 48.0;
  static const appBar = 56.0;
  static const chip = 28.0;
  static const icon = 20.0;
  static const reading = 680.0;

  static const sans = 'Inter';
  static const mono = 'JetBrains Mono';
}

extension VbContext on BuildContext {
  /// Falls back to the matching built theme under a bare MaterialApp.
  VbColors get vb {
    final t = Theme.of(this);
    return t.extension<VbColors>() ??
        (t.brightness == Brightness.dark ? VbColors.dark : VbColors.light);
  }

  VbReading get reading {
    final t = Theme.of(this);
    return t.extension<VbReading>() ??
        buildVbTheme(t.brightness).extension<VbReading>()!;
  }
}

ThemeData buildVbTheme(Brightness brightness, {bool monoEditor = true}) {
  final dark = brightness == Brightness.dark;
  final vb = dark ? VbColors.dark : VbColors.light;

  final bg = dark ? const Color(0xFF15141A) : const Color(0xFFFBFAF8);
  final surface = dark ? const Color(0xFF1C1B22) : const Color(0xFFFFFFFF);
  final raised = dark ? const Color(0xFF25242D) : const Color(0xFFF3F1EE);
  final border = dark ? const Color(0xFF34323D) : const Color(0xFFE4E1DC);
  final borderStrong = dark ? const Color(0xFF4A4755) : const Color(0xFFC9C5BF);
  final ink = dark ? const Color(0xFFECEBF1) : const Color(0xFF1D1B22);
  final muted = dark ? const Color(0xFFA3A1AD) : const Color(0xFF5F5C68);
  final accent = dark ? const Color(0xFFA48BFA) : const Color(0xFF6246D6);
  final onAccent = dark ? const Color(0xFF15102B) : const Color(0xFFFFFFFF);
  final accentSubtle = dark ? const Color(0xFF2A2341) : const Color(0xFFEEEAFC);
  final danger = dark ? const Color(0xFFF07A7A) : const Color(0xFFB3261E);
  final dangerSubtle = dark ? const Color(0xFF321A1B) : const Color(0xFFFBE7E5);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: accentSubtle,
    onPrimaryContainer: accent,
    secondary: accent,
    onSecondary: onAccent,
    tertiary: vb.warning,
    onTertiary: bg,
    error: danger,
    onError: bg,
    errorContainer: dangerSubtle,
    onErrorContainer: danger,
    surface: bg,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: borderStrong,
    outlineVariant: border,
    surfaceContainerLowest: bg,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: raised,
    surfaceContainerHighest: raised,
    inverseSurface: ink,
    onInverseSurface: bg,
    inversePrimary: accent,
    shadow: Colors.black,
    scrim: Colors.black,
  );

  const sans = TextStyle(fontFamily: Vb.sans);
  TextStyle ui(
    double size,
    double lh,
    FontWeight w, {
    double ls = 0,
    Color? color,
  }) => sans.copyWith(
    fontSize: size,
    height: lh / size,
    fontWeight: w,
    letterSpacing: ls,
    color: color ?? ink,
  );

  final mono = TextStyle(fontFamily: Vb.mono, color: ink);

  final textTheme = TextTheme(
    titleMedium: ui(17, 22, FontWeight.w600),
    titleLarge: ui(20, 26, FontWeight.w600),
    labelLarge: ui(13, 16, FontWeight.w500, ls: 0.1),
    bodyLarge: ui(15, 22, FontWeight.w400),
    bodyMedium: ui(15, 22, FontWeight.w400),
    bodySmall: ui(12, 16, FontWeight.w400, color: muted),
    labelMedium: ui(13, 16, FontWeight.w600, color: muted),
    labelSmall: ui(12, 16, FontWeight.w500, color: muted),
  );

  final reading = VbReading(
    h1: ui(26, 34, FontWeight.w700, ls: -0.3),
    h2: ui(21, 28, FontWeight.w600, ls: -0.2),
    h3: ui(18, 25, FontWeight.w600),
    body: ui(16, 26, FontWeight.w400),
    small: ui(14, 21, FontWeight.w400),
    editor: (monoEditor ? mono : sans.copyWith(color: ink)).copyWith(
      fontSize: 15,
      height: 24 / 15,
      fontWeight: FontWeight.w400,
    ),
    code: mono.copyWith(fontSize: 13.5, height: 21 / 13.5),
    codeLabel: mono.copyWith(
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4,
    ),
  );

  final pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Vb.radiusPill),
  );
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Vb.radiusMd),
  );

  OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Vb.radiusMd),
    borderSide: BorderSide(color: c, width: w),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: border,
    fontFamily: Vb.sans,
    textTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    extensions: [vb, reading],
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: Vb.appBar,
      titleTextStyle: textTheme.titleMedium,
      shape: Border(bottom: BorderSide(color: border)),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: muted, size: Vb.icon),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusLg),
        side: BorderSide(color: border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusLg),
        side: BorderSide(color: border),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyLarge!.copyWith(color: muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalBackgroundColor: raised,
      modalBarrierColor: vb.scrim,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Vb.radiusXl)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        minimumSize: const Size(64, Vb.touch),
        shape: rounded,
        textStyle: ui(15, 20, FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(64, Vb.touch),
        side: BorderSide(color: borderStrong),
        shape: rounded,
        textStyle: ui(15, 20, FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(64, 44),
        shape: pill,
        textStyle: ui(14, 20, FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: field(borderStrong),
      enabledBorder: field(borderStrong),
      focusedBorder: field(accent, 2),
      errorBorder: field(danger, 2),
      focusedErrorBorder: field(danger, 2),
      hintStyle: TextStyle(color: vb.inkFaint),
      helperStyle: textTheme.bodySmall,
      errorStyle: TextStyle(color: danger, fontSize: 12),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.28),
      selectionHandleColor: accent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ink,
      contentTextStyle: ui(14, 20, FontWeight.w400, color: bg),
      behavior: SnackBarBehavior.floating,
      shape: rounded,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        side: BorderSide(color: border),
      ),
      textStyle: textTheme.bodyLarge,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: raised,
        borderRadius: BorderRadius.circular(Vb.radiusMd),
        border: Border.all(color: borderStrong),
      ),
      textStyle: ui(14, 21, FontWeight.w400),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}
