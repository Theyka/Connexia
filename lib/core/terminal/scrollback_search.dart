import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class SearchMatch {
  final int line;
  final int startCol;
  final int endCol;

  const SearchMatch(this.line, this.startCol, this.endCol);
}

class ScrollbackSearch {
  final Terminal terminal;
  final TerminalController controller;

  final List<TerminalHighlight> _highlights = [];
  List<SearchMatch> matches = const [];
  int currentIndex = 0;
  int total = 0;

  ScrollbackSearch({required this.terminal, required this.controller});

  void clear() {
    for (final highlight in _highlights) {
      highlight.dispose();
    }
    _highlights.clear();
    matches = const [];
    currentIndex = 0;
    total = 0;
  }

  void _highlight(SearchMatch match, {required bool isCurrent}) {
    try {
      final p1 = terminal.buffer.createAnchor(match.startCol, match.line);
      final p2 = terminal.buffer.createAnchor(match.endCol, match.line);
      final highlight = controller.highlight(
        p1: p1,
        p2: p2,
        color: isCurrent ? const Color(0X80FFFFFF) : const Color(0X40FFFFFF),
      );
      _highlights.add(highlight);
    } catch (_) {}
  }

  int search(String query) {
    clear();
    if (query.isEmpty) return 0;

    final lower = query.toLowerCase();
    final matches = <SearchMatch>[];

    final lines = terminal.buffer.lines;
    for (var y = 0; y < lines.length; y++) {
      final text = lines[y].getText().toLowerCase();
      var index = 0;
      while (true) {
        final found = text.indexOf(lower, index);
        if (found < 0) break;
        matches.add(SearchMatch(y, found, found + query.length));
        index = found + 1;
      }
    }

    this.matches = matches;
    total = matches.length;
    currentIndex = 0;
    if (matches.isNotEmpty) {
      _highlight(matches.first, isCurrent: true);
    }
    return total;
  }

  void moveTo(int index) {
    if (matches.isEmpty) return;
    currentIndex = ((index % matches.length) + matches.length) % matches.length;

    for (final highlight in _highlights) {
      highlight.dispose();
    }
    _highlights.clear();

    for (var i = 0; i < matches.length; i++) {
      if (i == currentIndex) {
        _highlight(matches[i], isCurrent: true);
      } else {
        _highlight(matches[i], isCurrent: false);
      }
    }
  }
}
