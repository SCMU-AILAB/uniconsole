import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/core/theme/theme.dart';

/// 4pt 间距网格守卫（HANDOFF.md §13）。
///
/// 扫描界面源码里写死的内外边距、间隔与 Positioned 偏移，
/// 只允许 4 的倍数；2pt 半格必须通过 [AppSpacing.half] 使用。
void main() {
  test('AppSpacing 全部落在 4pt 网格上（half 除外）', () {
    const values = [
      AppSpacing.x1,
      AppSpacing.x2,
      AppSpacing.x3,
      AppSpacing.x4,
      AppSpacing.x5,
      AppSpacing.x6,
      AppSpacing.x7,
      AppSpacing.x8,
      AppSpacing.x9,
      AppSpacing.page,
      AppSpacing.card,
      AppSpacing.section,
    ];
    for (final v in values) {
      expect(v % 4, 0, reason: '$v 不在 4pt 网格上');
    }
    expect(AppSpacing.half, 2);
  });

  test('界面源码中写死的间距都是 4 的倍数', () {
    final dirs = ['lib/core', 'lib/features', 'lib/app'];
    final files = [
      for (final d in dirs)
        ...Directory(d)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];
    final number = RegExp(r'(?<![\w.$])(\d+(?:\.\d+)?)(?![\w.])');
    final violations = <String>[];

    void check(
      String file,
      String src,
      int at,
      String snippet,
      Iterable<String> numbers,
    ) {
      for (final n in numbers) {
        final v = double.parse(n);
        if (v % 4 != 0) {
          final line = '\n'.allMatches(src.substring(0, at)).length + 1;
          violations.add(
            '$file:$line  $n  ${snippet.replaceAll(RegExp(r'\s+'), ' ')}',
          );
        }
      }
    }

    String balanced(String src, int open) {
      var depth = 1, i = open;
      while (depth > 0 && i < src.length) {
        if (src[i] == '(') depth++;
        if (src[i] == ')') depth--;
        i++;
      }
      return src.substring(open, i - 1);
    }

    for (final f in files) {
      final src = f.readAsStringSync();
      // EdgeInsets.xxx(...)
      for (final m in RegExp(
        r'EdgeInsets(?:Directional)?\.\w+\(',
      ).allMatches(src)) {
        final body = balanced(src, m.end);
        check(
          f.path,
          src,
          m.start,
          body,
          number.allMatches(body).map((e) => e.group(1)!),
        );
      }
      // 纯间隔用的 SizedBox(width: n) / SizedBox(height: n)
      for (final m in RegExp(
        r'SizedBox\(\s*(?:width|height):\s*(\d+(?:\.\d+)?)\s*,?\s*\)',
      ).allMatches(src)) {
        final v = double.parse(m.group(1)!);
        // 大于 48 的通常是固定尺寸（标签列宽等），不是间隔。
        if (v <= 48) check(f.path, src, m.start, m.group(0)!, [m.group(1)!]);
      }
      // Wrap / Grid 间隔
      for (final m in RegExp(
        r'(?:spacing|runSpacing|mainAxisSpacing|crossAxisSpacing)\s*:\s*(\d+(?:\.\d+)?)\b',
      ).allMatches(src)) {
        check(f.path, src, m.start, m.group(0)!, [m.group(1)!]);
      }
      // Positioned 偏移（只看写死的正数；徽标等负偏移属于几何定位）
      for (final m in RegExp(r'Positioned\(([^()]*)').allMatches(src)) {
        for (final p in RegExp(
          r'\b(?:left|right|top|bottom):\s*(\d+(?:\.\d+)?)\b',
        ).allMatches(m.group(1)!)) {
          check(f.path, src, m.start, p.group(0)!, [p.group(1)!]);
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '不在 4pt 网格上的间距：\n${violations.join('\n')}',
    );
  });
}
