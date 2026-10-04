import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_bridge/markdown/find_in_note.dart';
import 'package:vault_bridge/markdown/obsidian_markdown.dart';
import 'package:vault_bridge/theme/vb_theme.dart';

/// Content type -> how many highlighted matches of 'zed' the preview must find.
const kDocs = <String, (String, int)>{
  'heading': ('# Title zed', 1),
  'para': ('Plain zed.', 1),
  'inline code': ('`inline zed code`', 1),
  'link': ('[link zed](https://x.y)', 1),
  'wikilink': ('[[wiki zed]]', 1),
  'tag': ('#zed tag', 1),
  'mark': ('==mark zed==', 1),
  'table': ('| a | b zed |\n|---|---|\n| zed | x |', 2),
  'fenced': ('```dart\nfinal zed = 1;\n```', 1),
  'ordered': ('1. num zed', 1),
  'task': ('- [ ] task zed', 1),
  'embed': ('![[zed.png]]', 1),
  'callout title': ('> [!note] Callout zed\n> body', 1),
  'callout body': ('> [!note] Callout\n> body zed', 1),
  'details': (
    '<details><summary>sum zed</summary>\n\ninside zed\n\n</details>',
    2,
  ),
  'blockquote': ('> quote zed', 1),
  'footnote': ('text[^1]\n\n[^1]: note zed', 1),
  'frontmatter': ('---\ntitle: zed note\n---\nbody', 1),
};

void main() {
  for (final e in kDocs.entries) {
    testWidgets('find in ${e.key}', (t) async {
      final finder = NoteFinder();
      await t.pumpWidget(
        MaterialApp(
          theme: buildVbTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: finder.query,
              builder: (_, _) => ObsidianMarkdownView(
                data: e.value.$1,
                callbacks: ObsidianCallbacks(finder: finder),
              ),
            ),
          ),
        ),
      );
      finder.setQuery('zed');
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(finder.count, e.value.$2);
    });
  }
}
