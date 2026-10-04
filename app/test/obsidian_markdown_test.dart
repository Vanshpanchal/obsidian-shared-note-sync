import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:vault_bridge/markdown/callouts.dart';
import 'package:vault_bridge/markdown/obsidian_markdown.dart';
import 'package:vault_bridge/markdown/obsidian_syntaxes.dart';

/// Parses with the Obsidian syntaxes and returns the top-level AST nodes.
List<md.Node> parse(String text) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  blockSyntaxes: obsidianBlockSyntaxes(),
  inlineSyntaxes: obsidianInlineSyntaxes(),
  encodeHtml: false,
).parseLines(text.split('\n'));

Iterable<md.Element> allElements(List<md.Node> nodes) sync* {
  for (final n in nodes) {
    if (n is md.Element) {
      yield n;
      yield* allElements(n.children ?? const []);
    }
  }
}

List<md.Element> tagged(String text, String tag) =>
    allElements(parse(text)).where((e) => e.tag == tag).toList();

void main() {
  group('syntaxes', () {
    test('callout with type, fold and title; nested body kept raw', () {
      final c = tagged(
        '> [!warning]- Be careful\n> body line\n> > [!tip] inner\n> > x',
        'obs-callout',
      ).single;
      expect(c.attributes['type'], 'warning');
      expect(c.attributes['fold'], '-');
      expect(c.attributes['title'], 'Be careful');
      expect(c.attributes['body'], 'body line\n> [!tip] inner\n> x');
      expect(tagged(c.attributes['body']!, 'obs-callout').single.attributes['type'], 'tip');
    });

    test('plain blockquote is not a callout', () {
      expect(tagged('> just a quote', 'obs-callout'), isEmpty);
      expect(tagged('> just a quote', 'blockquote'), hasLength(1));
    });

    test('wikilinks: alias, heading, block', () {
      final links = tagged(
        '[[Home]] [[Home|Go]] [[Home#Projects]] [[#Local]] [[Home#^abc]]',
        'obs-wikilink',
      );
      expect(links.map((e) => e.textContent), ['Home', 'Go', 'Home > Projects', 'Local', 'Home']);
      expect(links.map((e) => e.attributes['target']), [
        'Home',
        'Home',
        'Home#Projects',
        '#Local',
        'Home#^abc',
      ]);
    });

    test('embeds are not wikilinks', () {
      // Inside a sentence the embed stays inline.
      expect(
        tagged('see ![[image.png|300]] here', 'obs-embed').single.attributes,
        containsPair('size', '300'),
      );
      expect(tagged('see ![[image.png|300]] here', 'obs-wikilink'), isEmpty);
    });

    test('an embed alone on its line is a block, so pictures get their own row', () {
      final block = tagged('before\n\n![[image.png|300]]\n\nafter', 'obs-embed-block').single;
      expect(block.attributes, containsPair('target', 'image.png'));
      expect(block.attributes, containsPair('size', '300'));
      expect(tagged('![[image.png]]', 'obs-embed'), isEmpty);
      // Consecutive embed lines are separate blocks, even without a blank line between.
      expect(tagged('![[a.png]]\n![[b.png]]', 'obs-embed-block'), hasLength(2));
    });

    test('tags: nested, unicode; not headings, C#, escapes, numbers', () {
      final tags = tagged('#a #project/vault-bridge #નમસ્તે C#sharp \\#no #123 x#y', 'obs-tag');
      expect(tags.map((e) => e.textContent), ['a', 'project/vault-bridge', 'નમસ્તે']);
      expect(tagged('# Heading', 'obs-tag'), isEmpty);
    });

    test('highlight, comments, block ids', () {
      expect(tagged('a ==hi there== b', 'obs-mark').single.textContent, 'hi there');
      final p = tagged('keep %%hidden%% text ^block-1', 'p').single;
      expect(p.textContent, 'keep  text');
    });

    test('multi-line %% comment block is dropped', () {
      final nodes = parse('before\n\n%%\nsecret\n%%\n\nafter');
      expect(allElements(nodes).map((e) => e.textContent).join(' '), isNot(contains('secret')));
    });

    test('math inline and block; prices are not math', () {
      expect(tagged(r'x $E = mc^2$ y', 'obs-math-inline').single.attributes['tex'], 'E = mc^2');
      expect(tagged(r'costs $5 and $10 today', 'obs-math-inline'), isEmpty);
      expect(tagged('\$\$\n\\int x\n\$\$', 'obs-math-block').single.attributes['tex'], r'\int x');
      expect(tagged(r'$$a+b$$', 'obs-math-block').single.attributes['tex'], 'a+b');
    });

    test('inline code is untouched', () {
      expect(
        tagged('`#notatag ==no== %%keep%%`', 'code').single.textContent,
        '#notatag ==no== %%keep%%',
      );
      expect(tagged('`#notatag`', 'obs-tag'), isEmpty);
    });

    test('alt task statuses', () {
      final t = tagged('- [/] doing\n- [-] dropped\n- [ ] open\n- [x] done', 'obs-task');
      expect(t.map((e) => e.attributes['status']), ['/', '-']);
    });

    test('html: kbd, sub, details', () {
      expect(tagged('<kbd>Cmd</kbd>', 'obs-html').single.attributes['kind'], 'kbd');
      final d = tagged(
        '<details>\n<summary>More</summary>\n\nHidden **text**\n\n</details>',
        'obs-details',
      ).single;
      expect(d.attributes['summary'], 'More');
      expect(d.attributes['body'], 'Hidden **text**');
    });

    test('footnotes produce a footnotes section', () {
      final s = tagged('A[^1]\n\n[^1]: Note text.', 'section');
      expect(s.single.attributes['class'], 'footnotes');
    });

    test('frontmatter is split and parsed', () {
      final n = splitFrontmatter('---\ntitle: X\ntags:\n  - a\n  - b\ndone: true\n---\n# Body');
      expect(n.body, '# Body');
      expect(n.properties, {
        'title': 'X',
        'tags': ['a', 'b'],
        'done': true,
      });
      expect(splitFrontmatter('no frontmatter').properties, isNull);
      expect(splitFrontmatter('---\n: bad: [\n---\nx').rawFrontmatter, isNotNull);
    });

    test('callout aliases and unknown types', () {
      expect(calloutStyleFor('faq').color, calloutStyleFor('question').color);
      expect(calloutStyleFor('faq').label, 'Faq');
      expect(calloutStyleFor('whatever').color, calloutStyleFor('note').color);
    });
  });

  testWidgets('renders the full reference note without errors', (tester) async {
    final note = File('test/fixtures/obsidian_reference.md').readAsStringSync();
    tester.view.physicalSize = const Size(1200, 40000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ObsidianMarkdownView(data: note)),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PropertiesPanel), findsOneWidget);
    expect(find.byType(CalloutBox), findsAtLeastNWidgets(15));
    expect(find.byType(TagPill), findsAtLeastNWidgets(8));
    expect(find.byType(CodeBlock), findsAtLeastNWidgets(8));
    expect(find.byType(Math), findsAtLeastNWidgets(4));
    expect(find.textContaining('RENDERS IN OBSIDIAN', findRichText: true), findsWidgets);
    expect(find.textContaining('Go to Home', findRichText: true), findsOneWidget);
    expect(find.textContaining('This is a hidden comment', findRichText: true), findsNothing);
    expect(find.textContaining('directly. ^important-block', findRichText: true), findsNothing);
    expect(find.textContaining('link to it directly.', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('==highlight==', findRichText: true),
      findsOneWidget,
    ); // inside inline code only
    expect(find.textContaining('The first footnote.', findRichText: true), findsOneWidget);
    // Foldable closed callout starts collapsed.
    expect(
      find.textContaining('This content is hidden until expanded', findRichText: true),
      findsNothing,
    );
    await tester.tap(
      find.textContaining('Foldable callout (closed by default)', findRichText: true),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This content is hidden until expanded', findRichText: true),
      findsOneWidget,
    );
  });
}
