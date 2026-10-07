import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';

/// A small, dependency-free renderer for the subset of Markdown used in
/// Connexia release notes: ATX headings, bullet/ordered lists, blockquotes,
/// horizontal rules, **bold**, *italic*, `code` and [links](url).
///
/// It is intentionally forgiving — anything it does not recognise is shown as
/// plain text — so a stray character in a release body never breaks the dialog.
class MarkdownText extends StatelessWidget {
  final String data;
  final TextStyle? style;

  const MarkdownText(this.data, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final base =
        style ??
        TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.textSecondary);
    final blocks = parseMarkdownBlocks(data);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 7),
          _buildBlock(blocks[i], base),
        ],
      ],
    );
  }

  Widget _buildBlock(MarkdownBlock block, TextStyle base) {
    switch (block.kind) {
      case MarkdownBlockKind.heading:
        final scale = switch (block.level) {
          1 => 1.35,
          2 => 1.18,
          _ => 1.06,
        };
        final style = base.copyWith(
          fontSize: (base.fontSize ?? 12.5) * scale,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        );
        return Text.rich(
          TextSpan(children: parseInline(block.text, style)),
          style: style,
        );
      case MarkdownBlockKind.bullet:
        return _listRow('•', block.text, base);
      case MarkdownBlockKind.ordered:
        return _listRow('${block.level}.', block.text, base);
      case MarkdownBlockKind.quote:
        final style = base.copyWith(fontStyle: FontStyle.italic);
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.borderStrong, width: 2),
            ),
          ),
          child: Text.rich(
            TextSpan(children: parseInline(block.text, style)),
            style: style,
          ),
        );
      case MarkdownBlockKind.rule:
        return Container(height: 1, color: AppColors.border);
      case MarkdownBlockKind.paragraph:
        return Text.rich(
          TextSpan(children: parseInline(block.text, base)),
          style: base,
        );
    }
  }

  Widget _listRow(String marker, String text, TextStyle base) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 16,
          child: Text(marker, style: base.copyWith(color: AppColors.textFaint)),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(children: parseInline(text, base)),
            style: base,
          ),
        ),
      ],
    );
  }
}

enum MarkdownBlockKind { heading, bullet, ordered, quote, rule, paragraph }

class MarkdownBlock {
  final MarkdownBlockKind kind;
  final String text;

  /// Heading level (1-6) or the ordinal for ordered list items.
  final int level;

  const MarkdownBlock(this.kind, this.text, {this.level = 0});
}

final _ruleRe = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
final _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final _bulletRe = RegExp(r'^[-*+]\s+(.*)$');
final _orderedRe = RegExp(r'^(\d+)[.)]\s+(.*)$');
final _quoteRe = RegExp(r'^>\s?(.*)$');

/// Splits Markdown [source] into block-level elements. Wrapped lines are joined
/// into a single paragraph, and GitHub-style table rows are skipped.
List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final blocks = <MarkdownBlock>[];
  final paragraph = StringBuffer();

  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(
      MarkdownBlock(MarkdownBlockKind.paragraph, paragraph.toString().trim()),
    );
    paragraph.clear();
  }

  for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    // Table rows never render well inline; skip them.
    if (line.startsWith('|')) {
      flush();
      continue;
    }
    if (_ruleRe.hasMatch(line)) {
      flush();
      blocks.add(const MarkdownBlock(MarkdownBlockKind.rule, ''));
      continue;
    }
    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      flush();
      blocks.add(
        MarkdownBlock(
          MarkdownBlockKind.heading,
          heading.group(2)!.trim(),
          level: heading.group(1)!.length,
        ),
      );
      continue;
    }
    final quote = _quoteRe.firstMatch(line);
    if (quote != null) {
      flush();
      blocks.add(
        MarkdownBlock(MarkdownBlockKind.quote, quote.group(1)!.trim()),
      );
      continue;
    }
    final ordered = _orderedRe.firstMatch(line);
    if (ordered != null) {
      flush();
      blocks.add(
        MarkdownBlock(
          MarkdownBlockKind.ordered,
          ordered.group(2)!.trim(),
          level: int.tryParse(ordered.group(1)!) ?? 1,
        ),
      );
      continue;
    }
    final bullet = _bulletRe.firstMatch(line);
    if (bullet != null) {
      flush();
      blocks.add(
        MarkdownBlock(MarkdownBlockKind.bullet, bullet.group(1)!.trim()),
      );
      continue;
    }
    if (paragraph.isNotEmpty) paragraph.write(' ');
    paragraph.write(line);
  }
  flush();
  return blocks;
}

final _inlineRe = RegExp(
  r'\[([^\]]+)\]\(([^)]+)\)' // [label](url)
  r'|\*\*([^*]+)\*\*' // **bold**
  r'|__([^_]+)__' // __bold__
  r'|\*([^*]+)\*' // *italic*
  r'|_([^_]+)_' // _italic_
  r'|`([^`]+)`', // `code`
);

/// Parses inline formatting in [text] into spans styled relative to [base].
List<InlineSpan> parseInline(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var index = 0;

  for (final match in _inlineRe.allMatches(text)) {
    if (match.start > index) {
      spans.add(TextSpan(text: text.substring(index, match.start)));
    }

    if (match.group(1) != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _MarkdownLink(
            label: match.group(1)!,
            url: match.group(2)!,
            style: base.copyWith(
              color: AppColors.accent,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.accent,
            ),
          ),
        ),
      );
    } else if (match.group(3) != null || match.group(4) != null) {
      spans.add(
        TextSpan(
          text: match.group(3) ?? match.group(4),
          style: base.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      );
    } else if (match.group(5) != null || match.group(6) != null) {
      spans.add(
        TextSpan(
          text: match.group(5) ?? match.group(6),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else if (match.group(7) != null) {
      spans.add(
        TextSpan(
          text: match.group(7),
          style: base.copyWith(
            fontFamily: 'JetBrainsMono',
            fontSize: (base.fontSize ?? 12.5) - 0.5,
            color: AppColors.textPrimary,
            backgroundColor: AppColors.elevated,
          ),
        ),
      );
    }

    index = match.end;
  }

  if (index < text.length) {
    spans.add(TextSpan(text: text.substring(index)));
  }
  return spans;
}

class _MarkdownLink extends StatelessWidget {
  final String label;
  final String url;
  final TextStyle style;

  const _MarkdownLink({
    required this.label,
    required this.url,
    required this.style,
  });

  Future<void> _open() async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Text(label, style: style),
    );
  }
}
