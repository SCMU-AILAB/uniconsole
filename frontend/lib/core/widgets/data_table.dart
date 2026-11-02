import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'controls.dart';
import 'pressable.dart';

class AppDataColumn {
  const AppDataColumn(
    this.label, {
    this.flex = 1,
    this.width,
    this.alignEnd = false,
  });

  final String label;

  /// 按比例分配宽度（设计稿 grid-template-columns 的 fr）。
  final double flex;

  /// 固定宽度，优先于 [flex]。
  final double? width;
  final bool alignEnd;
}

class AppDataRow {
  const AppDataRow({
    required this.cells,
    this.selected = false,
    this.onTap,
    this.checked,
    this.onCheckedChanged,
    this.semanticLabel,
  });

  final List<Widget> cells;
  final bool selected;
  final VoidCallback? onTap;

  /// 批量选择勾选状态（表格开启 [AppDataTable.checkboxes] 时生效）。
  final bool? checked;
  final ValueChanged<bool>? onCheckedChanged;
  final String? semanticLabel;
}

/// 数据表（Roles.dc.html 成员表、Maintenance.dc.html 固件表）：
/// 11.5 号灰色表头、行选中、宽度不足时容器内横向滚动。
class AppDataTable extends StatelessWidget {
  const AppDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.minWidth = 620,
    this.checkboxes = false,
    this.rowPadding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.x3,
      vertical: AppSpacing.x3,
    ),
  });

  final List<AppDataColumn> columns;
  final List<AppDataRow> rows;

  /// 小于该宽度时横向滚动。
  final double minWidth;
  final bool checkboxes;
  final EdgeInsetsGeometry rowPadding;

  static const _gap = AppSpacing.x3;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;

    Widget line(List<Widget> cells, {Widget? lead}) => Row(
      children: [
        if (checkboxes) SizedBox(width: 28, child: lead),
        for (var i = 0; i < columns.length; i++) ...[
          if (i > 0) const SizedBox(width: _gap),
          if (columns[i].width != null)
            SizedBox(
              width: columns[i].width,
              child: _align(columns[i], cells[i]),
            )
          else
            Expanded(
              flex: (columns[i].flex * 10).round(),
              child: _align(columns[i], cells[i]),
            ),
        ],
      ],
    );

    final header = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: line([
        for (final col in columns)
          Semantics(
            header: true,
            child: Text(
              col.label,
              style: t.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
      ]),
    );

    final body = <Widget>[header];
    for (final r in rows) {
      // 表格行没有悬停态；按下时短暂高亮（§13）。
      Widget row(bool pressed) => AnimatedContainer(
        duration: AppMotion.fade(pressed: pressed),
        curve: AppMotion.highlightCurve,
        padding: rowPadding,
        decoration: BoxDecoration(
          color: r.selected
              ? c.rowSelected
              : pressed
              ? c.label.withValues(alpha: 0.05)
              : c.label.withValues(alpha: 0),
          border: Border(bottom: BorderSide(color: c.separatorSubtle)),
        ),
        child: DefaultTextStyle.merge(
          style: t.body.copyWith(color: c.label),
          child: line(
            r.cells,
            lead: checkboxes && r.checked != null
                ? AppCheckbox(
                    value: r.checked!,
                    onChanged: r.onCheckedChanged,
                    semanticLabel: '选择 ${r.semanticLabel ?? ''}',
                  )
                : null,
          ),
        ),
      );
      body.add(
        r.onTap == null
            ? row(false)
            : Pressable(
                onTap: r.onTap,
                selected: r.selected,
                semanticLabel: r.semanticLabel,
                focusRadius: 0,
                builder: (context, st) => row(st.pressed),
              ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final table = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: body,
        );
        if (box.maxWidth >= minWidth) return table;
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: SizedBox(width: minWidth, child: table),
          ),
        );
      },
    );
  }

  static Widget _align(AppDataColumn col, Widget child) => col.alignEnd
      ? Align(alignment: Alignment.centerRight, child: child)
      : Align(alignment: Alignment.centerLeft, child: child);
}
