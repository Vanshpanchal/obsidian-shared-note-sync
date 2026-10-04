import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_bridge/markdown/obsidian_markdown.dart';
import 'package:vault_bridge/theme/vb_theme.dart';

void main() {
  Future<List<String>> run(
    WidgetTester t,
    String md, {
    List<String>? taps,
  }) async {
    final seen = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildVbTheme(Brightness.light),
        home: Scaffold(
          body: ObsidianMarkdownView(
            data: md,
            callbacks: ObsidianCallbacks(
              onWikiLink: (target) => taps?.add(target),
              embedBuilder: (context, target, width) {
                seen.add(target);
                return target == 'My photo.png'
                    ? const Text('RENDERED-PHOTO')
                    : null;
              },
            ),
          ),
        ),
      ),
    );
    await t.pump();
    return seen;
  }

  testWidgets('![](Shared/assets/My%20photo.png) resolves to the attachment', (
    t,
  ) async {
    final seen = await run(t, '![](Shared/assets/My%20photo.png)');
    expect(seen, contains('Shared/assets/My photo.png'));
  });

  testWidgets('wikilink and markdown embeds both reach the embed builder', (
    t,
  ) async {
    final seen = await run(
      t,
      '![[My photo.png]]\n\n![](<My photo.png>)\n\n![](./My%20photo.png)',
    );
    expect(seen.where((s) => s.endsWith('My photo.png')).length, 3);
  });

  testWidgets(
    '[manual](Shared/assets/manual.pdf) opens the attachment, not the browser',
    (t) async {
      final taps = <String>[];
      await run(t, '[manual](Shared/assets/my%20manual.pdf)', taps: taps);
      await t.tap(find.text('manual'));
      expect(taps, ['Shared/assets/my manual.pdf']);
    },
  );
}
