import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mermaid_core/mermaid_core.dart' as m;
import 'package:vault_bridge/markdown/mermaid_view.dart';
import 'package:vault_bridge/theme/vb_theme.dart';

const diagrams = {
  'flowchart': 'graph TD\n  A[Start] --> B{Works?}\n  B -->|yes| C[Ship it]\n  B -->|no| A',
  'flowchart LR': 'graph LR\n  Phone --> Server\n  Server --> Vault',
  'sequence':
      'sequenceDiagram\n  Phone->>Server: save\n  Server-->>Phone: v19\n  Server->>Vault: write',
  'class':
      'classDiagram\n  class Note {\n    +String content\n    +int version\n  }\n  Note <|-- Shared',
  'state': 'stateDiagram-v2\n  [*] --> Saved\n  Saved --> Unsaved: edit\n  Unsaved --> Saved: sync',
  'er': 'erDiagram\n  NOTE ||--o{ ASSET : has',
  'pie': 'pie title Storage\n  "Images" : 6\n  "PDFs" : 3',
  'gantt':
      'gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section Build\n  Backend :a1, 2026-10-01, 3d\n  App :after a1, 4d',
  'journey': 'journey\n  title Day\n  section Morning\n    Wake: 3: Me',
  'mindmap': 'mindmap\n  root((VaultBridge))\n    App\n    Plugin\n    Backend',
};

void main() {
  for (final b in Brightness.values) {
    for (final e in diagrams.entries) {
      testWidgets('${b.name}: ${e.key} lays out and paints', (tester) async {
        late m.MermaidTheme theme;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildVbTheme(b),
            home: Builder(
              builder: (context) {
                theme = mermaidThemeFor(context);
                return const SizedBox();
              },
            ),
          ),
        );
        final result = MermaidResult.render(e.value, theme);
        expect(result.ok, isTrue, reason: result.error);
        final size = result.renderer!.size;
        expect(size.width, greaterThan(20));
        expect(size.height, greaterThan(20));

        await tester.pumpWidget(
          MaterialApp(
            theme: buildVbTheme(b),
            home: Scaffold(
              body: SingleChildScrollView(child: MermaidDiagram(renderer: result.renderer!)),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(CustomPaint), findsWidgets);
      });
    }
  }

  testWidgets('a syntax error is reported, not thrown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: MermaidBlock(source: 'graph TD\n  A -->')),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final shows =
        find.text('SYNTAX ERROR').evaluate().isNotEmpty ||
        find.text('MERMAID').evaluate().isNotEmpty;
    expect(shows, isTrue);
  });

  testWidgets('garbage input never throws out of the block', (tester) async {
    for (final src in ['', '???', 'notADiagram\n  x', 'graph TD\n  A[unclosed']) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(child: MermaidBlock(source: src)),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'source ${src.replaceAll('\n', '\\n')}');
    }
  });

  testWidgets('Source toggles between the diagram and its text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: MermaidBlock(source: 'graph LR\n  Phone --> Server')),
        ),
      ),
    );
    expect(find.byTooltip('Open full screen'), findsOneWidget);
    expect(find.textContaining('Phone --> Server'), findsNothing);

    await tester.tap(find.text('Source'));
    await tester.pump();
    expect(find.textContaining('Phone --> Server'), findsOneWidget);
    expect(find.byTooltip('Open full screen'), findsNothing);

    await tester.tap(find.text('Diagram'));
    await tester.pump();
    expect(find.byTooltip('Open full screen'), findsOneWidget);
  });

  testWidgets('full screen viewer opens from the expand button', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: MermaidBlock(source: 'graph LR\n  A --> B')),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open full screen'));
    await tester.pumpAndSettle();
    expect(find.byType(MermaidViewerScreen), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  group('full screen zoom', () {
    Future<void> openViewer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.dark),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: MermaidBlock(source: 'graph TD\n  A[Start] --> B{Works?}\n  B --> C[Ship]'),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();
    }

    String percent(WidgetTester tester) =>
        tester.widgetList<Text>(find.textContaining('%')).first.data!;

    testWidgets('starts fitted at 100% with zoom controls', (tester) async {
      await openViewer(tester);
      expect(percent(tester), '100%');
      expect(find.byTooltip('Zoom in'), findsOneWidget);
      expect(find.byTooltip('Zoom out'), findsOneWidget);
      expect(find.byTooltip('Fit to screen'), findsOneWidget);
    });

    testWidgets('zoom in and out change the percentage; fit returns to 100%', (tester) async {
      await openViewer(tester);
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(percent(tester), '140%');
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(percent(tester), '196%');
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pump();
      expect(percent(tester), '140%');
      await tester.tap(find.byTooltip('Fit to screen'));
      await tester.pump();
      expect(percent(tester), '100%');
    });

    testWidgets('zoom is limited at both ends', (tester) async {
      await openViewer(tester);
      for (var i = 0; i < 12; i++) {
        await tester.tap(find.byTooltip('Zoom out'));
        await tester.pump();
      }
      expect(percent(tester), '40%');
      for (var i = 0; i < 30; i++) {
        await tester.tap(find.byTooltip('Zoom in'));
        await tester.pump();
      }
      expect(percent(tester), '1400%');
    });

    testWidgets('double-tap zooms in, and a second double-tap goes back to fit', (tester) async {
      await openViewer(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(percent(tester), '250%');

      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(percent(tester), '100%');
    });
  });
}
