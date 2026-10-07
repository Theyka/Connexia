import 'package:connexia/ui/widgets/markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseMarkdownBlocks', () {
    test('classifies headings, lists, quotes and rules', () {
      final blocks = parseMarkdownBlocks('''
# Title
## Section
- one
- two
1. first
2. second
> note
---
text''');

      expect(blocks.map((b) => b.kind).toList(), [
        MarkdownBlockKind.heading,
        MarkdownBlockKind.heading,
        MarkdownBlockKind.bullet,
        MarkdownBlockKind.bullet,
        MarkdownBlockKind.ordered,
        MarkdownBlockKind.ordered,
        MarkdownBlockKind.quote,
        MarkdownBlockKind.rule,
        MarkdownBlockKind.paragraph,
      ]);
      expect(blocks[0].level, 1);
      expect(blocks[1].level, 2);
      expect(blocks[1].text, 'Section');
      expect(blocks[2].text, 'one');
      expect(blocks[4].level, 1); // ordered ordinal
      expect(blocks[5].level, 2);
      expect(blocks[6].text, 'note');
      expect(blocks[8].text, 'text');
    });

    test('joins wrapped lines and skips table rows', () {
      final blocks = parseMarkdownBlocks('| a | b |\nhello\nworld\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, MarkdownBlockKind.paragraph);
      expect(blocks.single.text, 'hello world');
    });

    test('treats a line starting with a star and no space as text', () {
      final blocks = parseMarkdownBlocks('*not a bullet*');
      expect(blocks.single.kind, MarkdownBlockKind.paragraph);
      expect(blocks.single.text, '*not a bullet*');
    });
  });

  group('parseInline', () {
    const base = TextStyle(fontSize: 12, color: Color(0xFF000000));

    test('parses bold, italic and code while keeping the text', () {
      final spans = parseInline('a **b** c *d* `e`', base);
      final spansText = spans.whereType<TextSpan>().map((s) => s.text).join();
      expect(spansText, 'a b c d e');

      TextSpan find(String text) =>
          spans.whereType<TextSpan>().firstWhere((s) => s.text == text);
      expect(find('b').style?.fontWeight, FontWeight.w700);
      expect(find('d').style?.fontStyle, FontStyle.italic);
      expect(find('e').style?.fontFamily, 'JetBrainsMono');
    });

    test('parses links into a widget span', () {
      final spans = parseInline('see [docs](https://example.com)', base);
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
      expect(spans.whereType<TextSpan>().map((s) => s.text).join(), 'see ');
    });

    test('leaves plain text untouched', () {
      final spans = parseInline('just words', base);
      expect(spans, hasLength(1));
      expect((spans.single as TextSpan).text, 'just words');
    });
  });
}
